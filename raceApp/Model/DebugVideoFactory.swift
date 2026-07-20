//
//  DebugVideoFactory.swift
//  raceApp
//
//  DEBUG-only: synthesizes dashcam-style test clips for the latest session so
//  the video pipeline (crop, gaps, stitching, sync) can be verified in the
//  simulator. Each clip is a hue-shifting color field with a moving progress
//  bar; clip 1 starts before the session and clip 3 runs past its end.
//

#if DEBUG
import Foundation
import AVFoundation
import UIKit
import SessionKit

enum DebugVideoFactory {

    /// Attach three synthetic clips to the session: head-cropped, mid (after a
    /// gap), and tail-cropped — the full dashcam scenario.
    static func populate(manifest: SessionManifest, store: SessionStore) async {
        guard (manifest.videos ?? []).isEmpty else { return }
        let duration = max(20, manifest.highlights?.durationSeconds ?? 60)
        let directory = VideoLibrary.videosDirectory(sessionDirectory: store.directory(for: manifest.id))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let specs: [(offset: TimeInterval, duration: TimeInterval, hue: CGFloat)] = [
            (-10, duration * 0.45 + 10, 0.58),          // starts pre-session → head crop
            (duration * 0.55, duration * 0.25, 0.08),   // gap 45–55%, then mid clip
            (duration * 0.85, duration * 0.30, 0.33),   // runs past the end → tail crop
        ]
        var updated = manifest
        var assets: [VideoAsset] = []
        for (index, spec) in specs.enumerated() {
            let name = "debug-clip-\(index + 1).mp4"
            let url = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            do {
                try await writeClip(to: url, seconds: spec.duration, hue: spec.hue)
            } catch {
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            assets.append(VideoAsset(fileName: name,
                                     wallClockStart: manifest.startedAtUTC.addingTimeInterval(spec.offset),
                                     duration: spec.duration,
                                     fileSizeBytes: size ?? nil))
        }
        updated.videos = assets
        try? store.save(updated)
    }

    /// H.264 640×360 @10fps: hue-shifting background + white progress bar.
    private static func writeClip(to url: URL, seconds: TimeInterval, hue: CGFloat) async throws {
        let width = 640, height = 360, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = max(2, Int(seconds * Double(fps)))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                &pixelBuffer)
            guard let pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) {
                let progress = CGFloat(frame) / CGFloat(frames)
                let color = UIColor(hue: (hue + progress * 0.2).truncatingRemainder(dividingBy: 1),
                                    saturation: 0.65, brightness: 0.5, alpha: 1)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: progress * CGFloat(width - 10), y: 0,
                                    width: 10, height: CGFloat(height)))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
#endif
