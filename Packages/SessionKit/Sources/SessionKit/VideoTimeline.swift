import Foundation

/// One imported video clip, stored in the session's `videos/` directory.
/// `wallClockStart` comes from the file's creation metadata (or a fallback);
/// the session-wide `videoSyncOffset` corrects camera-clock drift for all clips.
public struct VideoAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var wallClockStart: Date
    public var duration: TimeInterval
    public var fileSizeBytes: Int64?

    public init(id: UUID = UUID(), fileName: String, wallClockStart: Date,
                duration: TimeInterval, fileSizeBytes: Int64? = nil) {
        self.id = id
        self.fileName = fileName
        self.wallClockStart = wallClockStart
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
    }
}

/// A slice of one clip placed on the session timeline (both in seconds).
/// The virtual crop: only the overlap between clip and session survives.
public struct VideoSegment: Equatable, Sendable {
    public let assetId: UUID
    public let fileName: String
    /// Seconds into the video file where this slice starts.
    public let assetStart: TimeInterval
    /// Seconds into the session where this slice begins.
    public let sessionStart: TimeInterval
    public let duration: TimeInterval

    public var sessionEnd: TimeInterval { sessionStart + duration }
}

/// Pure mapping of clips → session-cropped, gap-aware playback segments.
public enum VideoTimeline {

    /// Compute the ordered, non-overlapping segments that cover the session.
    /// Clips fully outside the session window contribute nothing; partially
    /// overlapping clips are cropped; overlapping clips are trimmed so the
    /// earlier-starting clip yields to the next one.
    public static func segments(
        assets: [VideoAsset],
        sessionStartUTC: Date,
        sessionDuration: TimeInterval,
        syncOffset: TimeInterval
    ) -> [VideoSegment] {
        guard sessionDuration > 0 else { return [] }
        var placed: [VideoSegment] = assets.compactMap { asset in
            let start = asset.wallClockStart.timeIntervalSince(sessionStartUTC) + syncOffset
            let end = start + asset.duration
            let clippedStart = max(0, start)
            let clippedEnd = min(sessionDuration, end)
            guard clippedEnd - clippedStart > 0.05 else { return nil }
            return VideoSegment(
                assetId: asset.id,
                fileName: asset.fileName,
                assetStart: clippedStart - start,
                sessionStart: clippedStart,
                duration: clippedEnd - clippedStart
            )
        }
        placed.sort { $0.sessionStart < $1.sessionStart }

        // Resolve overlaps: earlier segment yields to the next one's start.
        var result: [VideoSegment] = []
        for segment in placed {
            if let last = result.last, segment.sessionStart < last.sessionEnd {
                let trimmed = segment.sessionStart - last.sessionStart
                result.removeLast()
                if trimmed > 0.05 {
                    result.append(VideoSegment(
                        assetId: last.assetId, fileName: last.fileName,
                        assetStart: last.assetStart, sessionStart: last.sessionStart,
                        duration: trimmed))
                }
            }
            result.append(segment)
        }
        return result
    }

    /// Fraction of the session covered by footage (0…1).
    public static func coverage(segments: [VideoSegment], sessionDuration: TimeInterval) -> Double {
        guard sessionDuration > 0 else { return 0 }
        let covered = segments.reduce(0) { $0 + $1.duration }
        return min(1, covered / sessionDuration)
    }

    /// Uncovered stretches of the session (for "no footage" UI).
    public static func gaps(segments: [VideoSegment], sessionDuration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var gaps: [(TimeInterval, TimeInterval)] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            if segment.sessionStart - cursor > 0.5 {
                gaps.append((cursor, segment.sessionStart))
            }
            cursor = max(cursor, segment.sessionEnd)
        }
        if sessionDuration - cursor > 0.5 {
            gaps.append((cursor, sessionDuration))
        }
        return gaps
    }
}

/// Fast value-at-time lookups on a recorded channel (for the video value strip).
public struct ChannelSampleCursor: Sendable {
    private let samples: [ChannelSample]

    public init(samples: [ChannelSample]) {
        self.samples = samples
    }

    public init(channel: ChannelId, sessionDirectory: URL) {
        self.samples = ChannelReader.samples(for: channel, inSessionDirectory: sessionDirectory)
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Nearest sample value at time `t` (same clock as the samples), or nil if
    /// the closest sample is further than `tolerance` away.
    public func value(at t: TimeInterval, tolerance: TimeInterval = 2.0) -> Double? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        var best: ChannelSample?
        if lo < samples.count { best = samples[lo] }
        if lo > 0, let candidate = best {
            if abs(samples[lo - 1].t - t) < abs(candidate.t - t) { best = samples[lo - 1] }
        } else if lo > 0 {
            best = samples[lo - 1]
        }
        guard let best, abs(best.t - t) <= tolerance else { return nil }
        return best.value
    }
}
