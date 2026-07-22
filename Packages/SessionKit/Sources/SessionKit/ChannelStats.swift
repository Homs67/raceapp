import Foundation

/// Rate / coverage stats derived from native `(t, value)` channel files.
public enum ChannelStats {

    public struct Rate: Equatable, Sendable {
        public var sampleCount: Int
        public var spanSeconds: Double
        public var measuredHz: Double
        public var medianIntervalMs: Double
    }

    /// Nominal source rate used for duty-cycle (nil = unknown / variable).
    public static func expectedHz(for channel: ChannelId) -> Double? {
        let id = channel.rawValue
        if id.hasPrefix("gps.") { return 1.0 }
        if id.hasPrefix("imu.") || id.hasPrefix("car.") { return 100.0 }
        if id.hasPrefix("baro.") { return 10.0 }
        if id.hasPrefix("device.") { return 0.2 }
        // OBD fast loop is adapter-limited; treat 15 Hz as a healthy target.
        if id == ChannelId.obd(.rpm).rawValue
            || id == ChannelId.obd(.speed).rawValue
            || id == ChannelId.obd(.throttle).rawValue
            || id == ChannelId.obd(.acceleratorPedal).rawValue {
            return 15.0
        }
        if id.hasPrefix("obd.") { return 0.2 } // slow sweep ~5 s
        return nil
    }

    public static func rate(from samples: [ChannelSample]) -> Rate? {
        guard samples.count >= 2 else {
            if samples.count == 1 {
                return Rate(sampleCount: 1, spanSeconds: 0, measuredHz: 0, medianIntervalMs: 0)
            }
            return nil
        }
        let span = samples[samples.count - 1].t - samples[0].t
        guard span > 1e-6 else {
            return Rate(sampleCount: samples.count, spanSeconds: 0, measuredHz: 0, medianIntervalMs: 0)
        }
        var intervals: [Double] = []
        intervals.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            let dt = samples[i].t - samples[i - 1].t
            if dt > 1e-6 { intervals.append(dt) }
        }
        intervals.sort()
        let medianDt = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
        return Rate(
            sampleCount: samples.count,
            spanSeconds: span,
            measuredHz: Double(samples.count - 1) / span,
            medianIntervalMs: medianDt * 1000
        )
    }

    public static func enrichSummary(id: ChannelId, samples: [ChannelSample]) -> SessionManifest.ChannelSummary {
        guard let stats = rate(from: samples) else {
            return SessionManifest.ChannelSummary(id: id, sampleCount: samples.count)
        }
        var duty: Double?
        if let expected = expectedHz(for: id), expected > 0 {
            duty = min(1, stats.measuredHz / expected)
        }
        return SessionManifest.ChannelSummary(
            id: id,
            sampleCount: stats.sampleCount,
            measuredHz: roundHz(stats.measuredHz),
            dutyCycle: duty.map { ($0 * 1000).rounded() / 1000 },
            spanSeconds: (stats.spanSeconds * 1000).rounded() / 1000,
            medianIntervalMs: (stats.medianIntervalMs * 100).rounded() / 100
        )
    }

    public static func enrichAll(inSessionDirectory directory: URL) -> [SessionManifest.ChannelSummary] {
        ChannelReader.channels(inSessionDirectory: directory).map { id in
            enrichSummary(id: id, samples: ChannelReader.samples(for: id, inSessionDirectory: directory))
        }
    }

    public static func obdTiming(inSessionDirectory directory: URL,
                                 sessionDuration: TimeInterval) -> SessionManifest.ObdTiming? {
        let candidates: [ChannelId] = [.obd(.rpm), .obd(.speed), .obd(.throttle)]
        for channel in candidates {
            let samples = ChannelReader.samples(for: channel, inSessionDirectory: directory)
            guard samples.count >= 2, let stats = rate(from: samples) else { continue }
            let coverage = sessionDuration > 0 ? min(1, stats.spanSeconds / sessionDuration) : nil
            return SessionManifest.ObdTiming(
                referenceChannel: channel.rawValue,
                sampleCount: stats.sampleCount,
                measuredHz: roundHz(stats.measuredHz),
                medianIntervalMs: (stats.medianIntervalMs * 100).rounded() / 100,
                spanSeconds: (stats.spanSeconds * 1000).rounded() / 1000,
                coverage: coverage.map { ($0 * 1000).rounded() / 1000 }
            )
        }
        return nil
    }

    private static func roundHz(_ hz: Double) -> Double {
        if hz >= 10 { return (hz * 10).rounded() / 10 }
        return (hz * 100).rounded() / 100
    }
}
