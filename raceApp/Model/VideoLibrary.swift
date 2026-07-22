//
//  VideoLibrary.swift
//  raceApp
//
//  Video import + virtual composition: copies clips into the session's
//  videos/ directory, reads their wall-clock metadata, and stitches the
//  session-cropped segments into one AVComposition (no re-encoding).
//

import Foundation
import AVFoundation
import Photos
import CoreTransferable
import SessionKit

/// Movie handoff from the Photos picker (copies to a temp URL we can import).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

enum VideoLibrary {

    static func videosDirectory(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("videos", isDirectory: true)
    }

    static func url(for asset: VideoAsset, sessionDirectory: URL) -> URL {
        videosDirectory(sessionDirectory: sessionDirectory).appendingPathComponent(asset.fileName)
    }

    // MARK: - Photos backup

    /// Ask for add-only Photos access (best done when camera is first turned ON).
    static func requestPhotoLibraryAddAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Save a session MP4 into Photos as a safety net for re-import.
    @discardableResult
    static func saveCopyToPhotoLibrary(_ fileURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard await requestPhotoLibraryAddAccess() else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Import

    /// Copy a picked file into the session and read its metadata.
    /// `fallbackStart` is used when the file carries no creation date
    /// (clip is then placed at session start; the sync nudge can move it).
    static func importVideo(from sourceURL: URL, sessionDirectory: URL,
                            fallbackStart: Date) async throws -> VideoAsset {
        let directory = videosDirectory(sessionDirectory: sessionDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString.prefix(8) + "-" + sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(String(fileName))
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let avAsset = AVURLAsset(url: destination)
        let duration = try await avAsset.load(.duration).seconds
        var created: Date?
        if let item = try? await avAsset.load(.creationDate) {
            created = try? await item.load(.dateValue)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil

        // Reconcile metadata vs filename timestamp: end-stamping dashcams get
        // corrected to the true start automatically.
        let inferred = VideoTimeline.inferredStart(
            embeddedDate: created, duration: duration, fileName: sourceURL.lastPathComponent)

        return VideoAsset(fileName: String(fileName),
                          wallClockStart: inferred.start ?? fallbackStart,
                          duration: duration,
                          fileSizeBytes: size ?? nil,
                          hasEmbeddedDate: inferred.start != nil)
    }

    static func deleteFile(for asset: VideoAsset, sessionDirectory: URL) {
        try? FileManager.default.removeItem(at: url(for: asset, sessionDirectory: sessionDirectory))
    }

    static func totalBytes(_ assets: [VideoAsset]) -> Int64 {
        assets.reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
    }

    // MARK: - Composition (footage-only compact timeline)

    struct BuiltComposition: Sendable {
        let composition: AVComposition
        let videoComposition: AVVideoComposition?
        /// Pixel size after preferredTransform (what the viewer should show).
        let displaySize: CGSize

        var isLandscape: Bool { displaySize.width > displaySize.height + 1 }
        var aspectRatio: CGFloat {
            guard displaySize.height > 1 else { return 16 / 9 }
            return displaySize.width / displaySize.height
        }
    }

    /// Stitch the cropped segments back-to-back: playback contains ONLY the
    /// parts of the session that have footage; uncovered data is skipped.
    /// Applies each clip's preferredTransform so landscape footage stays landscape.
    static func buildComposition(compact: [VideoTimeline.CompactSegment],
                                 sessionDirectory: URL) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return BuiltComposition(composition: composition, videoComposition: nil,
                                    displaySize: CGSize(width: 16, height: 9))
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        func time(_ seconds: TimeInterval) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        var displaySize = CGSize(width: 1920, height: 1080)
        var didSetDisplaySize = false
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        var hasVideo = false
        var maxFrameDuration = CMTime(value: 1, timescale: 30)

        for item in compact {
            let segment = item.segment
            let fileURL = videosDirectory(sessionDirectory: sessionDirectory)
                .appendingPathComponent(segment.fileName)
            let source = AVURLAsset(url: fileURL)
            let range = CMTimeRange(start: time(segment.assetStart), duration: time(segment.duration))
            let at = time(item.compStart)

            if let sourceVideo = try await source.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: at)
                hasVideo = true

                let natural = try await sourceVideo.load(.naturalSize)
                let transform = try await sourceVideo.load(.preferredTransform)
                let oriented = CGRect(origin: .zero, size: natural).applying(transform)
                let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                if !didSetDisplaySize, size.width > 1, size.height > 1 {
                    displaySize = size
                    didSetDisplaySize = true
                }
                if let minFrame = try? await sourceVideo.load(.minFrameDuration),
                   minFrame.isValid, minFrame.isNumeric, minFrame.seconds > 0 {
                    maxFrameDuration = minFrame
                }

                // preferredTransform puts the clip upright; scale into renderSize if needed.
                var fitted = transform
                if didSetDisplaySize, size.width > 1, size.height > 1 {
                    let scaleX = displaySize.width / size.width
                    let scaleY = displaySize.height / size.height
                    let scale = min(scaleX, scaleY)
                    if abs(scale - 1) > 0.001 {
                        let dx = (displaySize.width - size.width * scale) / 2
                        let dy = (displaySize.height - size.height * scale) / 2
                        fitted = transform
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                            .concatenating(CGAffineTransform(translationX: dx, y: dy))
                    }
                }
                layerInstruction.setTransform(fitted, at: at)
            }
            if let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: at)
            }
        }

        let duration = composition.duration
        guard duration.seconds > 0, hasVideo else {
            return BuiltComposition(composition: composition, videoComposition: nil,
                                    displaySize: displaySize)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = displaySize
        videoComposition.frameDuration = maxFrameDuration
        videoComposition.instructions = [instruction]

        return BuiltComposition(composition: composition, videoComposition: videoComposition,
                                displaySize: displaySize)
    }

    /// Oriented width×height for an on-disk clip (after preferredTransform).
    static func displaySize(ofFileAt url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let oriented = natural.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        return size.width > 1 && size.height > 1 ? size : nil
    }
}
