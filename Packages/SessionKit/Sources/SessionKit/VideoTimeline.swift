import Foundation

/// One video clip, stored in the session's `videos/` directory.
/// `wallClockStart` comes from phone capture time, file metadata, or a fallback;
/// the session-wide `videoSyncOffset` corrects camera-clock drift for all clips.
public struct VideoAsset: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case rear
        case front
        case imported
    }

    public var id: UUID
    public var fileName: String
    public var wallClockStart: Date
    public var duration: TimeInterval
    public var fileSizeBytes: Int64?
    /// Whether `wallClockStart` came from the file's own metadata (false =
    /// fallback placement; the clip needs manual sync).
    public var hasEmbeddedDate: Bool?
    /// Capture source. Defaults to `imported` for older manifests.
    public var role: Role

    public init(id: UUID = UUID(), fileName: String, wallClockStart: Date,
                duration: TimeInterval, fileSizeBytes: Int64? = nil,
                hasEmbeddedDate: Bool? = nil, role: Role = .imported) {
        self.id = id
        self.fileName = fileName
        self.wallClockStart = wallClockStart
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.hasEmbeddedDate = hasEmbeddedDate
        self.role = role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        wallClockStart = try c.decode(Date.self, forKey: .wallClockStart)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        hasEmbeddedDate = try c.decodeIfPresent(Bool.self, forKey: .hasEmbeddedDate)
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .imported
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

    /// Best-estimate recording START for a clip, reconciling the file's
    /// metadata date with a timestamp embedded in its filename.
    ///
    /// Many dashcams stamp the metadata creation date when the file is
    /// *finalized* (the END of recording) but put the true start time in the
    /// filename (e.g. `20260719214903_000651.mp4`). If metadata ≈ filename
    /// time + duration, the camera is end-stamped and the filename wins.
    /// Verified against a real 10-clip dashcam batch (all Δ = duration ±2s).
    public static func inferredStart(embeddedDate: Date?, duration: TimeInterval,
                                     fileName: String) -> (start: Date?, endStamped: Bool) {
        let fromName = filenameDate(fileName)
        guard let embeddedDate else {
            return (fromName, false) // no metadata at all — filename is better than nothing
        }
        if let fromName {
            let endStampDelta = abs(embeddedDate.timeIntervalSince(fromName.addingTimeInterval(duration)))
            if endStampDelta <= 15 {
                return (fromName, true) // metadata = end of file; filename has the start
            }
        }
        return (embeddedDate, false)
    }

    /// Extract a `yyyyMMddHHmmss` timestamp from a filename (dashcam pattern).
    /// Interpreted in UTC — same convention cameras use for their metadata
    /// dates, so comparisons between the two are timezone-consistent.
    public static func filenameDate(_ fileName: String) -> Date? {
        let digits = Array("0123456789")
        let chars = Array(fileName)
        var run = 0
        for (index, ch) in chars.enumerated() {
            run = digits.contains(ch) ? run + 1 : 0
            if run == 14 {
                let stamp = String(chars[(index - 13)...index])
                guard stamp.hasPrefix("20") else { continue }
                var components = DateComponents()
                components.year = Int(stamp.prefix(4))
                components.month = Int(stamp.dropFirst(4).prefix(2))
                components.day = Int(stamp.dropFirst(6).prefix(2))
                components.hour = Int(stamp.dropFirst(8).prefix(2))
                components.minute = Int(stamp.dropFirst(10).prefix(2))
                components.second = Int(stamp.dropFirst(12).prefix(2))
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                guard let month = components.month, (1...12).contains(month),
                      let day = components.day, (1...31).contains(day),
                      let hour = components.hour, hour < 24,
                      let minute = components.minute, minute < 60,
                      let second = components.second, second < 60 else { continue }
                return calendar.date(from: components)
            }
        }
        return nil
    }

    /// Assets used for the primary review composition: prefer rear (+ imported),
    /// exclude concurrent front when a rear clip exists.
    public static func primaryPlaybackAssets(_ assets: [VideoAsset]) -> [VideoAsset] {
        if assets.contains(where: { $0.role == .rear }) {
            return assets.filter { $0.role != .front }
        }
        return assets
    }

    /// Front-camera clips for PiP overlay during dual review.
    public static func frontPlaybackAssets(_ assets: [VideoAsset]) -> [VideoAsset] {
        assets.filter { $0.role == .front }
    }

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

    // MARK: - Compact (footage-only) timeline

    /// A cropped segment placed on the *compacted* playback timeline, where
    /// footage plays back-to-back and uncovered session stretches are skipped.
    public struct CompactSegment: Equatable, Sendable {
        public let segment: VideoSegment
        /// Seconds into the compacted playback timeline where this slice starts.
        public let compStart: TimeInterval
        public var compEnd: TimeInterval { compStart + segment.duration }
    }

    /// Pack cropped segments back-to-back: playback shows only covered data.
    public static func compact(_ segments: [VideoSegment]) -> [CompactSegment] {
        var cursor: TimeInterval = 0
        return segments.map { segment in
            let compact = CompactSegment(segment: segment, compStart: cursor)
            cursor += segment.duration
            return compact
        }
    }

    /// Playback (compacted) time → session/data time.
    public static func sessionTime(atCompositionTime t: TimeInterval,
                                   in compact: [CompactSegment]) -> TimeInterval {
        guard let first = compact.first else { return t }
        if t <= first.compStart { return first.segment.sessionStart }
        for (index, c) in compact.enumerated() {
            if t < c.compStart { return c.segment.sessionStart }
            // Treat adjoining composition ranges as half-open so the exact
            // boundary jumps across a session gap to the next footage slice.
            if t < c.compEnd || index == compact.index(before: compact.endIndex) {
                return min(c.segment.sessionEnd,
                           c.segment.sessionStart + (t - c.compStart))
            }
        }
        return compact[compact.count - 1].segment.sessionEnd
    }

    /// Session/data time → playback (compacted) time. Times inside an
    /// uncovered gap snap forward to the next covered segment.
    public static func compositionTime(atSessionTime t: TimeInterval,
                                       in compact: [CompactSegment]) -> TimeInterval {
        guard let first = compact.first else { return 0 }
        if t <= first.segment.sessionStart { return 0 }
        for c in compact {
            if t < c.segment.sessionStart { return c.compStart }
            if t <= c.segment.sessionEnd { return c.compStart + (t - c.segment.sessionStart) }
        }
        return compact[compact.count - 1].compEnd
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
