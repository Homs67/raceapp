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

    // MARK: - Composition (the virtual crop)

    /// Stitch the cropped segments into one composition whose timeline IS the
    /// session timeline (0…sessionDuration). Gaps become empty ranges so the
    /// player clock stays aligned with the data.
    static func buildComposition(segments: [VideoSegment], sessionDirectory: URL,
                                 sessionDuration: TimeInterval) async throws -> AVComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return composition
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        func time(_ seconds: TimeInterval) -> CMTime {
            CMTime(seconds: seconds, preferredTimescale: 600)
        }

        var cursor: TimeInterval = 0
        var transformSet = false
        for segment in segments {
            // Explicit empty edit for any gap before this segment
            if segment.sessionStart - cursor > 0.05 {
                let gap = CMTimeRange(start: time(cursor), duration: time(segment.sessionStart - cursor))
                videoTrack.insertEmptyTimeRange(gap)
                audioTrack?.insertEmptyTimeRange(gap)
            }
            let fileURL = videosDirectory(sessionDirectory: sessionDirectory)
                .appendingPathComponent(segment.fileName)
            let source = AVURLAsset(url: fileURL)
            let range = CMTimeRange(start: time(segment.assetStart), duration: time(segment.duration))
            if let sourceVideo = try await source.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: time(segment.sessionStart))
                if !transformSet {
                    videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    transformSet = true
                }
            }
            if let sourceAudio = try? await source.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: time(segment.sessionStart))
            }
            cursor = max(cursor, segment.sessionEnd)
        }
        // Extend to the full session so the scrubber maps 1:1 to data time
        if sessionDuration - cursor > 0.05 {
            videoTrack.insertEmptyTimeRange(
                CMTimeRange(start: time(cursor), duration: time(sessionDuration - cursor)))
        }
        return composition
    }
}
