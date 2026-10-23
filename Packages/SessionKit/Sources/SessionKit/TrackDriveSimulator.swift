//
//  TrackDriveSimulator.swift
//  SessionKit
//
//  Drives a virtual car around a track centerline with a physics-lite
//  (quasi-static point-mass) speed profile: slow in corners, fast on straights.
//  Deterministic and pure — the same component powers demo mode (a believable
//  on-track drive with no car) and the golden test fixture for the lap-timing
//  and coaching engines.
//
//  Method: for each centerline point compute curvature radius r, cap speed at
//  v_max = min(topSpeed, √(µ·g·r)); then a backward pass bounds it by braking
//  and a forward pass by acceleration, yielding a continuous racing-style speed
//  profile. Integrating ds/v gives a time-parameterised lap that we sample.
//

import Foundation
import simd

public struct GeoPoint: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

public struct TrackDriveSimulator: Sendable {

    public struct Config: Sendable {
        /// Fraction of the physics limit actually driven (0…1). 1 = at the limit.
        public var pace: Double
        /// Surface/tyre grip coefficient — ND2 on 200TW ≈ 1.0.
        public var grip: Double
        public var topSpeedMps: Double
        public var maxAccelG: Double
        public var maxBrakeG: Double
        /// Wheel power per kg of car (W/kg) — ND2 ≈ 98 kW at the wheels / 1,150 kg.
        public var powerPerKg: Double
        /// Aero + rolling drag as deceleration per (m/s)² — ½·ρ·CdA / m.
        public var dragPerMeter: Double
        public init(pace: Double = 0.85, grip: Double = 1.0, topSpeedMps: Double = 62,
                    maxAccelG: Double = 0.55, maxBrakeG: Double = 1.0,
                    powerPerKg: Double = 85, dragPerMeter: Double = 0.00032) {
            self.pace = pace; self.grip = grip; self.topSpeedMps = topSpeedMps
            self.maxAccelG = maxAccelG; self.maxBrakeG = maxBrakeG
            self.powerPerKg = powerPerKg; self.dragPerMeter = dragPerMeter
        }
    }

    public struct Sample: Equatable, Sendable {
        public let lap: Int
        public let distance: Double        // metres along the current lap
        public let position: GeoPoint
        public let headingDeg: Double      // 0 = north, clockwise
        public let speedMps: Double
        public let lateralG: Double        // + = turning right
        public let longitudinalG: Double   // + = accelerating
    }

    private let pts: [GeoPoint]
    private let s: [Double]        // cumulative distance at each point (m), closed
    private let v: [Double]        // speed profile at each point (m/s)
    private let tAt: [Double]      // cumulative time at each point (s)
    private let signedCurv: [Double] // 1/r with sign (+ right turn)
    private let accelG: [Double]     // longitudinal g at each point, smoothed
    public let lapLengthMeters: Double
    public let lapTime: TimeInterval

    private static let g = 9.80665

    public init(centerline: [GeoPoint], config: Config = Config()) {
        precondition(centerline.count >= 8, "centerline too short")
        // Deduplicate consecutive identical points, keep closed loop implicit.
        var p = centerline
        if let f = p.first, let l = p.last, Self.dist(f, l) < 1 { p.removeLast() }
        self.pts = p
        let n = p.count

        // Local equirectangular metres about the centroid.
        let lat0 = p.reduce(0) { $0 + $1.lat } / Double(n) * .pi / 180
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0)
        let xy = p.map { SIMD2($0.lon * mLon, $0.lat * mLat) }

        // Cumulative distance (closed: last segment wraps to point 0).
        var s = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let a = xy[i], b = xy[(i + 1) % n]
            s[i + 1] = s[i] + simd_length(b - a)
        }
        self.s = s
        self.lapLengthMeters = s[n]

        // Signed curvature via the Menger three-point circle over a small window.
        let w = max(1, n / 220)
        var curv = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = xy[(i - w + n) % n], b = xy[i], c = xy[(i + w) % n]
            let ab = b - a, bc = c - b, ac = c - a
            let cross = ab.x * bc.y - ab.y * bc.x          // + = left turn
            let la = simd_length(ab), lb = simd_length(bc), lc = simd_length(ac)
            let denom = la * lb * lc
            let k = denom < 1e-6 ? 0 : (2 * abs(cross)) / denom
            curv[i] = k * (cross >= 0 ? -1 : 1)             // + right turn
        }
        // OSM centerlines wobble at the metre scale; a car's path doesn't. Average the
        // curvature over ~±25 m so lateral g builds and fades like a real corner.
        let spacing = s[n] / Double(n)
        curv = Self.smoothed(curv, halfWindow: max(1, Int((25 / spacing).rounded())), passes: 2)
        self.signedCurv = curv

        // Speed profile: grip-limited cap, then braking (backward) & accel (forward) passes.
        let cap = curv.map { k -> Double in
            let r = abs(k) < 1e-6 ? .infinity : 1 / abs(k)
            let vGrip = (config.grip * Self.g * r).squareRoot()
            return min(config.topSpeedMps, vGrip) * max(0.05, min(1, config.pace))
        }
        var v = cap
        let aB = config.maxBrakeG * Self.g, aA = config.maxAccelG * Self.g
        // Two wrap-around sweeps each so the profile converges across the seam.
        for _ in 0..<2 {
            for step in 0..<n {                             // backward: braking limit
                let i = (n - 1 - step + n) % n, j = (i + 1) % n
                let ds = s[i + 1] - s[i]
                v[i] = min(v[i], (v[j] * v[j] + 2 * aB * ds).squareRoot())
            }
            for step in 0..<n {                             // forward: accel limit
                let i = step % n, h = (i - 1 + n) % n
                let seg = s[h + 1] - s[h]                    // distance from h to i
                // Traction-limited at low speed, power- and drag-limited at high speed,
                // so long g fades toward zero down a straight instead of staying pinned.
                let aPow = config.powerPerKg / max(v[h], 5) - config.dragPerMeter * v[h] * v[h]
                let a = max(0, min(aA, aPow))
                v[i] = min(v[i], (v[h] * v[h] + 2 * a * seg).squareRoot())
            }
        }
        self.v = v

        // Longitudinal g per point from v·dv/ds, smoothed over ~±15 m: per-segment
        // differences on a 4 m grid are spiky, a real car's pitch isn't.
        var acc = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let ds = s[i + 1] - s[i], j = (i + 1) % n
            acc[i] = ds < 1e-6 ? 0 : (v[j] * v[j] - v[i] * v[i]) / (2 * ds) / Self.g
        }
        self.accelG = Self.smoothed(acc, halfWindow: max(1, Int((15 / spacing).rounded())), passes: 2)

        // Time parameterisation: dt = ds / average speed over each segment.
        var tAt = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let ds = s[i + 1] - s[i]
            let vAvg = max(0.5, 0.5 * (v[i] + v[(i + 1) % n]))
            tAt[i + 1] = tAt[i] + ds / vAvg
        }
        self.tAt = tAt
        self.lapTime = tAt[n]
    }

    /// Sample the drive at an absolute elapsed time; laps repeat seamlessly.
    public func sample(atElapsed elapsed: TimeInterval) -> Sample {
        let n = pts.count
        let lap = Int(floor(elapsed / lapTime))
        let tl = elapsed - Double(lap) * lapTime
        // Locate segment by cumulative time.
        var i = 0
        while i < n && tAt[i + 1] <= tl { i += 1 }
        if i >= n { i = n - 1 }
        let segT = tAt[i + 1] - tAt[i]
        let f = segT < 1e-6 ? 0 : (tl - tAt[i]) / segT
        let a = pts[i], b = pts[(i + 1) % n]
        let pos = GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)
        let j = (i + 1) % n
        let speed = v[i] + (v[j] - v[i]) * f
        let ds = s[i + 1] - s[i]
        // Blend between points so g changes smoothly rather than stepping every 4 m.
        let longG = accelG[i] + (accelG[j] - accelG[i]) * f
        let latG = (signedCurv[i] + (signedCurv[j] - signedCurv[i]) * f) * speed * speed / Self.g
        return Sample(lap: lap, distance: s[i] + ds * f, position: pos,
                      headingDeg: Self.bearing(a, b), speedMps: max(0, speed),
                      lateralG: latG, longitudinalG: longG)
    }

    /// Circular moving average (the lap is a loop), applied `passes` times.
    private static func smoothed(_ a: [Double], halfWindow w: Int, passes: Int) -> [Double] {
        let n = a.count
        var out = a
        for _ in 0..<passes {
            let src = out
            for i in 0..<n {
                var sum = 0.0
                for d in -w...w { sum += src[(i + d + n) % n] }
                out[i] = sum / Double(2 * w + 1)
            }
        }
        return out
    }

    // MARK: - geo helpers
    private static func dist(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let mLat = 110_540.0, mLon = 111_320.0 * cos(a.lat * .pi / 180)
        return (((b.lat - a.lat) * mLat) * ((b.lat - a.lat) * mLat)
              + ((b.lon - a.lon) * mLon) * ((b.lon - a.lon) * mLon)).squareRoot()
    }
    private static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
