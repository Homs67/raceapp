import Foundation

/// How a session's footage lines up with its data, set in the Video sync
/// screen: one clock offset per camera (a GoPro and a dashcam are never wrong
/// by the same amount) and the crop that bounds what review plays.
public struct VideoSync: Codable, Equatable, Sendable {
    public var frontOffset: TimeInterval
    public var rearOffset: TimeInterval
    /// Crop in session seconds; may reach past the session where a clip does.
    /// nil = no crop (the whole recording).
    public var cropStart: TimeInterval?
    public var cropEnd: TimeInterval?

    public init(frontOffset: TimeInterval = 0, rearOffset: TimeInterval = 0,
                cropStart: TimeInterval? = nil, cropEnd: TimeInterval? = nil) {
        self.frontOffset = frontOffset
        self.rearOffset = rearOffset
        self.cropStart = cropStart
        self.cropEnd = cropEnd
    }

    public func offset(for camera: VideoAsset.Camera) -> TimeInterval {
        camera == .front ? frontOffset : rearOffset
    }

    public mutating func setOffset(_ value: TimeInterval, for camera: VideoAsset.Camera) {
        if camera == .front { frontOffset = value } else { rearOffset = value }
    }

    /// The part of the session review shows: the crop clipped to the session.
    /// nil when there's no crop.
    public func reviewWindow(sessionDuration: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard cropStart != nil || cropEnd != nil else { return nil }
        let lo = max(0, cropStart ?? 0)
        let hi = min(sessionDuration, cropEnd ?? sessionDuration)
        return lo < hi ? lo...hi : nil
    }
}

public extension SessionManifest {
    /// The saved alignment, or the legacy single offset applied to both cameras.
    var effectiveVideoSync: VideoSync {
        videoSync ?? VideoSync(frontOffset: videoSyncOffset ?? 0, rearOffset: videoSyncOffset ?? 0)
    }

    var sessionDuration: TimeInterval { highlights?.durationSeconds ?? 0 }
}

/// Pure geometry for the Video sync timeline: one axis (session seconds) that
/// spans the session and every clip, so either can sit before or after the
/// other.
public enum VideoSyncLayout {

    /// A clip's span in session seconds once its camera offset is applied.
    public static func span(of asset: VideoAsset, sessionStartUTC: Date,
                            offset: TimeInterval) -> ClosedRange<TimeInterval> {
        let start = asset.wallClockStart.timeIntervalSince(sessionStartUTC) + offset
        return start...(start + max(0, asset.duration))
    }

    /// The shared axis: the session [0, duration] plus every clip.
    public static func axis(sessionDuration: TimeInterval,
                            spans: [ClosedRange<TimeInterval>]) -> ClosedRange<TimeInterval> {
        let lo = min(0, spans.map(\.lowerBound).min() ?? 0)
        let hi = max(sessionDuration, spans.map(\.upperBound).max() ?? sessionDuration)
        return lo...max(hi, lo + 1)
    }

    /// Keep a dragged crop inside the axis and at least `minLength` long.
    public static func clampCrop(_ crop: ClosedRange<TimeInterval>, axis: ClosedRange<TimeInterval>,
                                 minLength: TimeInterval = 1) -> ClosedRange<TimeInterval> {
        var lo = max(axis.lowerBound, min(crop.lowerBound, axis.upperBound - minLength))
        var hi = min(axis.upperBound, max(crop.upperBound, axis.lowerBound + minLength))
        if hi - lo < minLength {
            if crop.lowerBound != lo { lo = hi - minLength } else { hi = lo + minLength }
        }
        return lo...hi
    }

    /// When none of a camera's clips touch the session — a wrong time zone, a
    /// reset camera clock, a file with no date — the offset that moves its
    /// first clip to the session start, so it lands somewhere draggable
    /// instead of hours away. nil when the clips already overlap the session.
    public static func rescueOffset(spans: [ClosedRange<TimeInterval>],
                                    sessionDuration: TimeInterval) -> TimeInterval? {
        guard let first = spans.map(\.lowerBound).min() else { return nil }
        let overlaps = spans.contains { $0.upperBound > 0 && $0.lowerBound < sessionDuration }
        return overlaps ? nil : -first
    }

    /// Fraction (0…1) of `t` along the axis, for drawing.
    public static func fraction(_ t: TimeInterval, axis: ClosedRange<TimeInterval>) -> Double {
        let len = axis.upperBound - axis.lowerBound
        return len > 0 ? (t - axis.lowerBound) / len : 0
    }
}
