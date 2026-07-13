import Foundation

/// Post-session check that calibrated G-force is physically consistent:
///
/// **Longitudinal:** car.longG must track d(gps.speed)/dt — two fully
/// independent sensors (IMU vs GPS doppler). High correlation with a scale
/// near 1.0 means leveling + forward alignment worked.
///
/// **Lateral (informational):** |car.latG| should track speed × |rotation rate|
/// (centripetal acceleration). Uses rotation magnitude as a yaw proxy, so it's
/// noisier — reported but not part of the verdict.
public struct GForceValidation: Sendable, Equatable {

    public enum Verdict: String, Sendable {
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
    public var pairCount: Int

    public static func validate(sessionDirectory directory: URL) -> GForceValidation {
        let longG = ChannelReader.samples(for: .carLongG, inSessionDirectory: directory)
        guard longG.count > 50 else {
            return GForceValidation(verdict: .noCalibratedData, longCorrelation: nil,
                                    longScale: nil, latCorrelation: nil, pairCount: 0)
        }
        // Downsample speed to ~1 Hz so windowing is GPS-cadence independent
        // (real GPS is 1 Hz; demo publishes at 10 Hz).
        let speed = downsample(
            ChannelReader.samples(for: .gpsSpeed, inSessionDirectory: directory), minDt: 0.9)

        // Pair each consecutive GPS interval's acceleration with the mean
        // calibrated longitudinal G over the same window.
        var gpsAccel: [Double] = []
        var imuLong: [Double] = []
        var cursor = 0
        for i in 1..<max(1, speed.count) {
            let t0 = speed[i - 1].t
            let t1 = speed[i].t
            let dt = t1 - t0
            guard dt > 0.4, dt < 3 else { continue }
            let accelG = (speed[i].value - speed[i - 1].value) / dt / 9.81
            while cursor < longG.count, longG[cursor].t < t0 { cursor += 1 }
            var j = cursor
            var sum = 0.0
            var n = 0
            while j < longG.count, longG[j].t <= t1 {
                sum += longG[j].value
                n += 1
                j += 1
            }
            guard n >= 5 else { continue }
            gpsAccel.append(accelG)
            imuLong.append(sum / Double(n))
        }

        guard gpsAccel.count >= 20, spread(gpsAccel) > 0.02 else {
            return GForceValidation(verdict: .insufficientData, longCorrelation: nil,
                                    longScale: nil, latCorrelation: nil, pairCount: gpsAccel.count)
        }

        let r = pearson(gpsAccel, imuLong)
        let scale = slopeThroughOrigin(x: gpsAccel, y: imuLong)
        let latR = lateralCorrelation(directory: directory, speed: speed)

        let verdict: Verdict
        switch (r, scale) {
        case (let r?, let s?) where r >= 0.75 && (0.6...1.4).contains(s): verdict = .verified
        case (let r?, _) where r >= 0.5: verdict = .marginal
        default: verdict = .failed
        }
        return GForceValidation(verdict: verdict, longCorrelation: r, longScale: scale,
                                latCorrelation: latR, pairCount: gpsAccel.count)
    }

    // MARK: - Lateral (yaw-proxy, informational)

    private static func lateralCorrelation(directory: URL, speed: [ChannelSample]) -> Double? {
        let latG = ChannelReader.samples(for: .carLatG, inSessionDirectory: directory)
        let yaw = ChannelReader.samples(for: .imuYawRate, inSessionDirectory: directory)
        guard latG.count > 50, yaw.count > 50, speed.count > 10 else { return nil }
        var predicted: [Double] = []
        var measured: [Double] = []
        var latCursor = 0
        var yawCursor = 0
        for i in 1..<speed.count {
            let t0 = speed[i - 1].t
            let t1 = speed[i].t
            guard t1 - t0 > 0.4, t1 - t0 < 3 else { continue }
            let v = (speed[i].value + speed[i - 1].value) / 2
            guard v > 3 else { continue } // centripetal check meaningless when crawling
            func meanAbs(_ samples: [ChannelSample], _ cursor: inout Int) -> Double? {
                while cursor < samples.count, samples[cursor].t < t0 { cursor += 1 }
                var j = cursor
                var sum = 0.0
                var n = 0
                while j < samples.count, samples[j].t <= t1 {
                    sum += abs(samples[j].value)
                    n += 1
                    j += 1
                }
                return n >= 5 ? sum / Double(n) : nil
            }
            guard let lat = meanAbs(latG, &latCursor), let omega = meanAbs(yaw, &yawCursor) else { continue }
            predicted.append(v * omega / 9.81)
            measured.append(lat)
        }
        guard predicted.count >= 20 else { return nil }
        return pearson(predicted, measured)
    }

    // MARK: - Math

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
