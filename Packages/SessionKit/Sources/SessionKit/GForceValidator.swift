import Foundation

/// Post-session check that calibrated G-force is physically consistent with GPS
/// — two fully independent sensors (IMU chip vs. satellite doppler).
///
/// **Longitudinal:** car.longG vs d(gps.speed)/dt.
/// **Lateral:** car.latG vs signed centripetal acceleration v·d(course)/dt
/// (GPS course-rate — mount-independent, unlike device yaw).
///
/// iPhone GPS speed/course are doppler-filtered and lag the IMU by ~1–3 s, so
/// the validator searches a small lag range and reports the best alignment
/// (calibrated real-world data: r≈0.88 long / r≈0.79 lat at ~2 s lag).
public struct GForceValidation: Codable, Sendable, Equatable {

    public enum Verdict: String, Codable, Sendable {
        case verified          // longitudinal r and scale in range
        case marginal          // correlated but scale/noise off
        case failed            // calibrated data contradicts GPS
        case noCalibratedData  // session predates calibration / never calibrated
        case insufficientData  // too short / too little speed variation
    }

    public var verdict: Verdict
    public var longCorrelation: Double?
    public var longScale: Double?       // slope car.longG vs GPS accel; ~1.0 = correct
    public var latCorrelation: Double?
    public var gpsLagSeconds: Double?   // IMU-vs-GPS timing offset used
    public var pairCount: Int

    public init(verdict: Verdict, longCorrelation: Double?, longScale: Double?,
                latCorrelation: Double?, gpsLagSeconds: Double?, pairCount: Int) {
        self.verdict = verdict
        self.longCorrelation = longCorrelation
        self.longScale = longScale
        self.latCorrelation = latCorrelation
        self.gpsLagSeconds = gpsLagSeconds
        self.pairCount = pairCount
    }

    public static func validate(sessionDirectory directory: URL) -> GForceValidation {
        let longG = ChannelReader.samples(for: .carLongG, inSessionDirectory: directory)
        guard longG.count > 50 else {
            return GForceValidation(verdict: .noCalibratedData, longCorrelation: nil, longScale: nil,
                                    latCorrelation: nil, gpsLagSeconds: nil, pairCount: 0)
        }
        // ~1 Hz speed regardless of source cadence (real GPS 1 Hz, demo 10 Hz)
        let speed = downsample(ChannelReader.samples(for: .gpsSpeed, inSessionDirectory: directory), minDt: 0.9)
        let course = downsample(ChannelReader.samples(for: .gpsCourse, inSessionDirectory: directory), minDt: 0.9)
        let latG = ChannelReader.samples(for: .carLatG, inSessionDirectory: directory)

        // GPS-acceleration windows (~2 s), remembering each window's bounds
        struct Window {
            let t0: TimeInterval
            let t1: TimeInterval
            let accelG: Double
        }
        var windows: [Window] = []
        for i in 2..<max(2, speed.count) {
            let s0 = speed[i - 2]
            let s1 = speed[i]
            let dt = s1.t - s0.t
            guard dt > 1.2, dt < 5 else { continue }
            windows.append(Window(t0: s0.t, t1: s1.t, accelG: (s1.value - s0.value) / dt / 9.81))
        }
        guard windows.count >= 20, spread(windows.map(\.accelG)) > 0.02 else {
            return GForceValidation(verdict: .insufficientData, longCorrelation: nil, longScale: nil,
                                    latCorrelation: nil, gpsLagSeconds: nil, pairCount: windows.count)
        }

        // Search the GPS lag that best aligns IMU to GPS (0…3 s, 0.5 s steps)
        let longAverager = WindowAverager(samples: longG)
        var best: (lag: Double, r: Double, scale: Double, n: Int)?
        for lag in stride(from: 0.0, through: 3.0, by: 0.5) {
            var xs: [Double] = []
            var ys: [Double] = []
            for w in windows {
                guard let mean = longAverager.mean(from: w.t0 - lag, to: w.t1 - lag) else { continue }
                xs.append(w.accelG)
                ys.append(mean)
            }
            guard xs.count >= 20, let r = pearson(xs, ys), let s = slopeThroughOrigin(x: xs, y: ys) else { continue }
            if best == nil || r > best!.r {
                best = (lag, r, s, xs.count)
            }
        }
        guard let best else {
            return GForceValidation(verdict: .insufficientData, longCorrelation: nil, longScale: nil,
                                    latCorrelation: nil, gpsLagSeconds: nil, pairCount: 0)
        }

        let latR = lateralCorrelation(latG: latG, speed: speed, course: course, lag: best.lag)

        let verdict: Verdict
        if best.r >= 0.75, (0.5...1.5).contains(best.scale) {
            verdict = .verified
        } else if best.r >= 0.5 {
            verdict = .marginal
        } else {
            verdict = .failed
        }
        return GForceValidation(verdict: verdict, longCorrelation: best.r, longScale: best.scale,
                                latCorrelation: latR, gpsLagSeconds: best.lag, pairCount: best.n)
    }

    // MARK: - Lateral: signed centripetal vs GPS course-rate

    private static func lateralCorrelation(latG: [ChannelSample], speed: [ChannelSample],
                                           course: [ChannelSample], lag: Double) -> Double? {
        guard latG.count > 50, course.count > 10, speed.count > 10 else { return nil }
        let latAverager = WindowAverager(samples: latG)
        let speedAverager = WindowAverager(samples: speed)
        var predicted: [Double] = []
        var measured: [Double] = []
        for i in 2..<course.count {
            let c0 = course[i - 2]
            let c1 = course[i]
            let dt = c1.t - c0.t
            guard dt > 1.2, dt < 5 else { continue }
            var dpsi = (c1.value - c0.value).truncatingRemainder(dividingBy: 360)
            if dpsi > 180 { dpsi -= 360 }
            if dpsi < -180 { dpsi += 360 }
            guard abs(dpsi) < 90 else { continue } // standstill course jumps
            guard let v = speedAverager.mean(from: c0.t, to: c1.t), v > 4 else { continue }
            guard let lat = latAverager.mean(from: c0.t - lag, to: c1.t - lag) else { continue }
            // GPS course is clockwise-positive (right turn) → +lat under our convention
            predicted.append(v * (dpsi * .pi / 180) / dt / 9.81)
            measured.append(lat)
        }
        guard predicted.count >= 20 else { return nil }
        return pearson(predicted, measured)
    }

    // MARK: - Helpers

    /// O(log n) range means over a time-sorted channel via prefix sums.
    private struct WindowAverager {
        private let times: [TimeInterval]
        private let prefix: [Double]

        init(samples: [ChannelSample]) {
            times = samples.map(\.t)
            var acc = 0.0
            var sums: [Double] = [0]
            sums.reserveCapacity(samples.count + 1)
            for sample in samples {
                acc += sample.value
                sums.append(acc)
            }
            prefix = sums
        }

        func mean(from t0: TimeInterval, to t1: TimeInterval) -> Double? {
            let lo = lowerBound(t0)
            let hi = lowerBound(t1)
            guard hi - lo >= 5 else { return nil }
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }

        private func lowerBound(_ t: TimeInterval) -> Int {
            var lo = 0
            var hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    private static func downsample(_ samples: [ChannelSample], minDt: TimeInterval) -> [ChannelSample] {
        var result: [ChannelSample] = []
        for sample in samples where result.isEmpty || sample.t - result[result.count - 1].t >= minDt {
            result.append(sample)
        }
        return result
    }

    private static func spread(_ values: [Double]) -> Double {
        guard let min = values.min(), let max = values.max() else { return 0 }
        return max - min
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx
            let dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    private static func slopeThroughOrigin(x: [Double], y: [Double]) -> Double? {
        var sxy = 0.0, sxx = 0.0
        for i in 0..<x.count {
            sxy += x[i] * y[i]
            sxx += x[i] * x[i]
        }
        guard sxx > 1e-12 else { return nil }
        return sxy / sxx
    }
}
