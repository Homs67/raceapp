import Foundation

/// Minimal 3-vector for frame math.
public struct Vector3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vector3 {
        let m = magnitude
        return m > 1e-9 ? self * (1 / m) : .zero
    }
}

/// Automatic phone→car frame calibration, per mount, no user ceremony:
///
/// 1. **Leveling** — while the phone is quasi-static (parked or steady cruise),
///    average CoreMotion's gravity vector to find the car's "down" in device
///    coordinates (~1.5 s of samples).
/// 2. **Alignment** — during the first clean speed-up (GPS speed clearly
///    increasing), the horizontal component of user acceleration points
///    forward. Accumulate until confident.
///
/// After both, `carFrame(userAccel:)` rotates any device-frame acceleration
/// into car axes: `longG` +forward (accel) / −braking, `latG` +right / −left.
/// Pure value type — feed it samples, ask for the transform. Reset per session
/// (mounts move between drives).
public struct CarFrameCalibrator: Sendable {

    public enum Phase: Equatable, Sendable {
        case leveling
        case aligning
        case calibrated
    }

    public private(set) var phase: Phase = .leveling

    // Tunables (g units / m/s² / samples at ~100 Hz)
    private let quasiStaticMaxAccel = 0.06     // |userAccel| below this = static enough to level
    private let levelingSamplesNeeded = 150    // ~1.5 s
    private let speedingUpThreshold = 0.5      // m/s² sustained GPS speed trend
    private let alignMinHorizontalG = 0.10     // ignore weaker pulls
    private let alignWeightNeeded = 15.0       // Σ|horiz g| ≈ 0.15g × 100 samples ≈ 1 s of firm accel

    private var gravityAccum = Vector3.zero
    private var gravityCount = 0
    private var down = Vector3.zero
    private var forwardAccum = Vector3.zero
    private var forwardWeight = 0.0
    private var forward = Vector3.zero
    private var right = Vector3.zero

    private var lastSpeed: (mps: Double, t: TimeInterval)?
    private var speedTrend = 0.0 // smoothed m/s²

    public init() {}

    public mutating func reset() {
        self = CarFrameCalibrator()
    }

    /// Feed GPS speed (any cadence; 1 Hz is fine).
    public mutating func ingestSpeed(_ mps: Double, at t: TimeInterval) {
        if let last = lastSpeed, t > last.t, t - last.t < 5 {
            let accel = (mps - last.mps) / (t - last.t)
            speedTrend = 0.6 * speedTrend + 0.4 * accel
        }
        lastSpeed = (mps, t)
    }

    /// Feed one device-motion sample (gravity + gravity-removed user accel, both
    /// device frame, g units).
    public mutating func ingestMotion(gravity: Vector3, userAccel: Vector3) {
        switch phase {
        case .leveling:
            guard userAccel.magnitude < quasiStaticMaxAccel else { return }
            gravityAccum = gravityAccum + gravity
            gravityCount += 1
            if gravityCount >= levelingSamplesNeeded {
                down = gravityAccum.normalized
                phase = .aligning
            }

        case .aligning:
            guard speedTrend > speedingUpThreshold else { return }
            let horizontal = userAccel - down * userAccel.dot(down)
            guard horizontal.magnitude > alignMinHorizontalG else { return }
            forwardAccum = forwardAccum + horizontal
            forwardWeight += horizontal.magnitude
            if forwardWeight >= alignWeightNeeded {
                let projected = forwardAccum - down * forwardAccum.dot(down)
                forward = projected.normalized
                right = forward.cross(down * -1).normalized // forward × up = right (right-handed)
                phase = .calibrated
            }

        case .calibrated:
            break
        }
    }

    /// Device-frame user acceleration → car-frame G. nil until calibrated.
    public func carFrame(userAccel: Vector3) -> (latG: Double, longG: Double)? {
        guard phase == .calibrated else { return nil }
        return (latG: userAccel.dot(right), longG: userAccel.dot(forward))
    }
}
