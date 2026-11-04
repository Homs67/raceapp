import Foundation

/// Streaming computation of session highlights (R4.2) — fed sample-by-sample
/// during recording, or replayed from files during crash recovery.
public struct HighlightsAccumulator: Sendable {

    private var maxSpeed: Double = 0
    private var speedSum: Double = 0
    private var speedCount: Int = 0
    private var distance: Double = 0
    private var lastSpeedSample: ChannelSample?
    private var maxRpm: Double = 0
    private var peakLatG: Double = 0
    private var peakLongG: Double = 0
    private var calPeakLatG: Double = 0
    private var calPeakLongG: Double = 0
    private var hasCalibratedG = false
    private var elevationGain: Double = 0
    private var lastAltitude: Double?
    private var coolantMin: Double?
    private var coolantMax: Double?

    public init() {}

    /// Live distance integrated so far (metres).
    public var distanceMeters: Double { distance }

    /// Nothing was sampled across a pause, so the next sample does not follow
    /// on from the last one. Drop the anchors that integrate between samples —
    /// left in place they charge the pause as distance and as elevation gain.
    public mutating func noteDiscontinuity() {
        lastSpeedSample = nil
        lastAltitude = nil
    }

    public mutating func add(channel: ChannelId, value: Double, t: TimeInterval) {
        switch channel {
        case .gpsSpeed:
            let speed = max(0, value)
            maxSpeed = max(maxSpeed, speed)
            speedSum += speed
            speedCount += 1
            if let previous = lastSpeedSample, t > previous.t {
                // Trapezoidal distance integration over GPS speed
                distance += (speed + previous.value) / 2 * min(t - previous.t, 5)
            }
            lastSpeedSample = ChannelSample(t: t, value: speed)
        case ChannelId.obd(.rpm), .canRpm:
            maxRpm = max(maxRpm, value)
        case .carLatG: // auto-calibrated car frame — preferred when present
            hasCalibratedG = true
            calPeakLatG = max(calPeakLatG, abs(value))
        case .carLongG:
            hasCalibratedG = true
            calPeakLongG = max(calPeakLongG, abs(value))
        case .imuAccelX: // raw device frame — fallback until calibration completes
            peakLatG = max(peakLatG, abs(value))
        case .imuAccelY:
            peakLongG = max(peakLongG, abs(value))
        case .baroRelativeAltitude:
            if let last = lastAltitude, value > last {
                elevationGain += value - last
            }
            lastAltitude = value
        case ChannelId.obd(.coolantTemp):
            coolantMin = min(coolantMin ?? value, value)
            coolantMax = max(coolantMax ?? value, value)
        default:
            break
        }
    }

    /// `recordedSeconds` is the summed length of the session's segments, which
    /// is shorter than the wall-clock span whenever the driver paused. Without
    /// it the duration counts time nothing was written.
    public func finalize(startUptime: TimeInterval, endUptime: TimeInterval,
                         recordedSeconds: TimeInterval? = nil) -> SessionManifest.Highlights {
        var highlights = SessionManifest.Highlights()
        highlights.durationSeconds = recordedSeconds ?? max(0, endUptime - startUptime)
        highlights.distanceMeters = distance
        highlights.maxSpeedMps = maxSpeed
        highlights.avgSpeedMps = speedCount > 0 ? speedSum / Double(speedCount) : 0
        highlights.maxRpm = maxRpm
        highlights.peakLatG = hasCalibratedG ? calPeakLatG : peakLatG
        highlights.peakLongG = hasCalibratedG ? calPeakLongG : peakLongG
        highlights.elevationGainMeters = elevationGain
        highlights.coolantMinC = coolantMin
        highlights.coolantMaxC = coolantMax
        return highlights
    }
}
