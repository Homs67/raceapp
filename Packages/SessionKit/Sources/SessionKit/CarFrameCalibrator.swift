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

/// Automatic sensor→car frame calibration, per mount, no user ceremony.
///
/// 1. **Leveling** — while quasi-static, average the gravity vector to find the
///    car's "down" in sensor coordinates, and the gyroscope's zero offset.
/// 2. **Alignment** — continuously least-squares fit the forward axis: find the
///    direction `u` in which measured acceleration best predicts the
///    acceleration GPS actually observed, across every window of the drive.
///
/// The alignment used to lock onto a *single* acceleration event. On a real
/// drive (2026-09-11) that event happened while the car was still turning out
/// of a street, and the resulting forward axis was ~58° off for the entire
/// session — braking bled into cornering, and because a rotated axis still
/// correlates well, only the scale gave it away. A fit over hundreds of
/// windows averages one bad event away instead of being defined by it, and it
/// keeps improving as the drive goes on.
///
/// Works for any rigidly-held sensor — phone in a cradle or a bolted-in logger.
/// Pure value type: feed it samples, ask for the transform.
public struct CarFrameCalibrator: Sendable {

    public enum Phase: Equatable, Sendable {
        case leveling
        case aligning
        case calibrated
    }

    /// How well the fitted axis explains GPS-measured acceleration.
    public struct FitQuality: Equatable, Sendable {
        /// Windows contributing to the fit; more is better.
        public let windowCount: Int
        /// Length of the fitted projection before normalising. A correctly
        /// scaled sensor on a correctly levelled frame gives ~1.0; well below
        /// that means the axis is still absorbing error.
        public let scale: Double
        /// Range of GPS accelerations seen — a fit from only gentle driving is
        /// poorly conditioned however many windows it has.
        public let accelSpread: Double

        public var isTrustworthy: Bool { windowCount >= 20 && (0.8...1.25).contains(scale) }
    }

    public private(set) var phase: Phase = .leveling
    public private(set) var fitQuality: FitQuality?
    /// Gyroscope zero-offset measured while stationary (rad/s or °/s — whatever
    /// unit was fed in). A real RaceBox Micro showed a steady 1.2 °/s on one
    /// axis, which integrates into drift if left uncorrected.
    public private(set) var gyroBias: Vector3?

    // Tunables
    private let quasiStaticMaxAccel = 0.06     // |userAccel| g below this = static enough to level
    private let levelingSamplesNeeded = 150    // ~1.5 s at 100 Hz
    /// Reverse shows up as *rising* speed (GPS speed is unsigned), which would
    /// teach the fit a backwards forward axis. Real driving clears this well
    /// before any manoeuvring speed.
    private let minimumFitSpeed = 3.0          // m/s
    private let windowSeconds = 1.0
    private let minimumWindowsToSolve = 10
    private let minimumAccelSpread = 0.05      // g between the softest and hardest window
    private let resolveEvery = 4

    // Leveling
    private var gravityAccum = Vector3.zero
    private var gyroAccum = Vector3.zero
    private var levelingCount = 0
    private var down = Vector3.zero

    // Continuous alignment — normal equations, O(1) memory
    private var mtm = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
    private var mtb = [Double](repeating: 0, count: 3)
    private var windowCount = 0
    private var windowsSinceSolve = 0
    private var minAccel = Double.greatestFiniteMagnitude
    private var maxAccel = -Double.greatestFiniteMagnitude

    // Window accumulation
    private var windowAccelSum = Vector3.zero
    private var windowSampleCount = 0
    private var windowStart: (speed: Double, t: TimeInterval)?
    private var lastSpeed: (speed: Double, t: TimeInterval)?

    private var forward = Vector3.zero
    private var right = Vector3.zero

    public init() {}

    public mutating func reset() {
        self = CarFrameCalibrator()
    }

    // MARK: - Input

    /// Feed speed from whichever source is authoritative (phone GPS at 1 Hz or
    /// a logger at 25 Hz — the window is time-based, so cadence doesn't matter).
    public mutating func ingestSpeed(_ mps: Double, at t: TimeInterval) {
        defer { lastSpeed = (mps, t) }
        guard let start = windowStart else {
            windowStart = (mps, t)
            return
        }
        let elapsed = t - start.t
        guard elapsed >= windowSeconds else { return }
        // A long stall (locked screen, lost fix) isn't a window, it's a gap.
        guard elapsed <= 5 else {
            resetWindow(from: (mps, t))
            return
        }
        closeWindow(start: start, end: (mps, t), elapsed: elapsed)
        resetWindow(from: (mps, t))
    }

    /// Feed one motion sample in sensor coordinates: gravity direction and
    /// gravity-removed acceleration, both in g, plus optional rotation rate.
    public mutating func ingestMotion(gravity: Vector3, userAccel: Vector3,
                                      rotationRate: Vector3? = nil) {
        switch phase {
        case .leveling:
            guard userAccel.magnitude < quasiStaticMaxAccel else { return }
            gravityAccum = gravityAccum + gravity
            if let rotationRate { gyroAccum = gyroAccum + rotationRate }
            levelingCount += 1
            if levelingCount >= levelingSamplesNeeded {
                down = gravityAccum.normalized
                // Stationary rotation is zero by definition, so whatever the
                // gyro reports here is its offset.
                gyroBias = gyroAccum * (1 / Double(levelingCount))
                phase = .aligning
            }

        case .aligning, .calibrated:
            windowAccelSum = windowAccelSum + userAccel
            windowSampleCount += 1
        }
    }

    /// Rotation rate with the measured zero-offset removed.
    public func correctedRotation(_ rate: Vector3) -> Vector3 {
        guard let gyroBias else { return rate }
        return rate - gyroBias
    }

    // MARK: - Output

    /// Sensor-frame acceleration → car-frame G. nil until aligned.
    /// `longG` is +forward / −braking, `latG` is +right / −left.
    public func carFrame(userAccel: Vector3) -> (latG: Double, longG: Double)? {
        guard phase == .calibrated else { return nil }
        return (latG: userAccel.dot(right), longG: userAccel.dot(forward))
    }

    // MARK: - Fitting

    private mutating func resetWindow(from sample: (speed: Double, t: TimeInterval)) {
        windowStart = sample
        windowAccelSum = .zero
        windowSampleCount = 0
    }

    private mutating func closeWindow(start: (speed: Double, t: TimeInterval),
                                      end: (speed: Double, t: TimeInterval),
                                      elapsed: TimeInterval) {
        guard phase != .leveling, windowSampleCount >= 3 else { return }
        // Exclude crawling and reversing: below this, GPS speed is noisy and
        // its unsigned magnitude can't tell forward from backward.
        guard min(start.speed, end.speed) >= minimumFitSpeed else { return }

        let gpsAccelG = (end.speed - start.speed) / elapsed / 9.81
        let mean = windowAccelSum * (1 / Double(windowSampleCount))

        let m = [mean.x, mean.y, mean.z]
        for i in 0..<3 {
            for j in 0..<3 { mtm[i][j] += m[i] * m[j] }
            mtb[i] += m[i] * gpsAccelG
        }
        windowCount += 1
        windowsSinceSolve += 1
        minAccel = min(minAccel, gpsAccelG)
        maxAccel = max(maxAccel, gpsAccelG)

        let spread = maxAccel - minAccel
        guard windowCount >= minimumWindowsToSolve, spread >= minimumAccelSpread,
              windowsSinceSolve >= (phase == .calibrated ? resolveEvery : 1) else { return }
        windowsSinceSolve = 0
        solve(spread: spread)
    }

    private mutating func solve(spread: Double) {
        // Ridge term. Straight-line driving makes every sample vector point the
        // same way, so MᵀM is rank-deficient and the direction perpendicular to
        // the data is unconstrained — an exact solve would return garbage for
        // it (or refuse). A tiny λ selects the minimum-norm solution, which is
        // the one with no perpendicular component: exactly the forward axis we
        // want. Scaled to the data so it stays negligible against real signal.
        let trace = mtm[0][0] + mtm[1][1] + mtm[2][2]
        guard trace > 0 else { return }
        let lambda = 1e-4 * trace / 3
        var regularized = mtm
        for i in 0..<3 { regularized[i][i] += lambda }

        guard let u = Self.solve3x3(regularized, mtb) else { return }
        // The fitted direction is whatever best predicts longitudinal
        // acceleration; force it into the horizontal plane that leveling
        // established, since forward cannot have a vertical component.
        let horizontal = u - down * u.dot(down)
        let scale = horizontal.magnitude
        guard scale > 1e-6 else { return }

        forward = horizontal.normalized
        right = forward.cross(down * -1).normalized
        fitQuality = FitQuality(windowCount: windowCount, scale: scale, accelSpread: spread)
        phase = .calibrated
    }

    /// Gaussian elimination with partial pivoting. Returns nil if singular —
    /// which happens when the drive has no acceleration variety to fit against.
    static func solve3x3(_ a: [[Double]], _ b: [Double]) -> Vector3? {
        var m = (0..<3).map { a[$0] + [b[$0]] }
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(m[$0][column]) < abs(m[$1][column]) } ?? column
            m.swapAt(column, pivot)
            guard abs(m[column][column]) > 1e-12 else { return nil }
            for row in 0..<3 where row != column {
                let factor = m[row][column] / m[column][column]
                for k in column..<4 { m[row][k] -= factor * m[column][k] }
            }
        }
        return Vector3(m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2])
    }
}
