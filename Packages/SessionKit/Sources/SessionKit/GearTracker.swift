import Foundation

/// What the gear widget shows, built on `GearEstimator`'s ratio match with the
/// context a human uses: a car that sits at idle is in neutral (or clutch-in,
/// which looks the same), a car crawling away with the engine above idle is
/// launching in 1st even while the clutch slips, and a gear doesn't vanish
/// for the moment the ratio is unresolved mid-shift.
///
/// **A gear is only read while the engine is coupled to the wheels.** With
/// the clutch pressed — a shift, a coast, a stop — the revs fall on their own
/// and the RPM/speed ratio sweeps through every higher gear on the way down.
/// On the Oct 27 2026 drive the bare ratio read 2nd → 3rd → 4th → 5th → 6th
/// on one clutch-in coast. So a gear is accepted only when the RPM/speed
/// pairs of the last 0.6 s (longer when speed arrives slowly, e.g. 1 Hz phone
/// GPS) — at least three, spanning 0.3 s, each with the RPM read within 0.4 s
/// of the speed — agree to 5%; otherwise the last coupled gear is held. That
/// also absorbs 1 Hz phone speed lagging a second behind the RPM, which on
/// its own made braking read as an upshift. And braking never moves the
/// gear up.
///
/// Reverse is deliberately not detected. The ND2's reverse ratio sits where a
/// slipping clutch in 2nd also lands, and a speed-change-versus-G detector
/// misread parking manoeuvres often enough to be worse than nothing.
///
/// Result: `0` = neutral; `1...` = gear. Never nil: with no engine data at
/// all the car isn't being driven in a gear, and a dash reads as a fault.
public struct GearTracker: Sendable {

    public let estimator: GearEstimator
    /// Below this the engine is idling, whatever the pedal does next.
    public let idleCeilingRpm: Double
    /// Below this the car is stationary or crawling; the speed/RPM ratio is
    /// meaningless here (clutch slip, GPS noise), so context decides.
    public let crawlSpeedMps: Double
    /// Keep the last coupled gear this long once coupling is lost.
    public let holdSeconds: TimeInterval

    /// Coupling test: the pairs of the last `minWindow` (or 3.2 speed-sample
    /// intervals, if longer) — at least `pairsNeeded`, spanning `pairSpan` —
    /// within `pairSpread` of each other. An RPM reading belongs to a speed
    /// sample if it was taken within `pairWindow` of it.
    static let pairsNeeded = 3
    static let minWindow: TimeInterval = 0.6
    static let pairSpan: TimeInterval = 0.3
    static let pairSpread = 1.05
    static let pairWindow: TimeInterval = 0.4
    /// Brake pedal % above which the car is braking.
    static let brakingPercent = 5.0

    private var gear: Int?
    private var lastCoupledT: TimeInterval = -.infinity
    private var pairs: [(t: TimeInterval, ratio: Double)] = []
    private var lastSpeedT: TimeInterval?
    /// Interval between the last two speed samples (25 Hz logger vs 1 Hz phone).
    private var speedInterval: TimeInterval = 0.04

    public init(estimator: GearEstimator = GearEstimator(),
                idleCeilingRpm: Double = 1250,
                crawlSpeedMps: Double = 2,
                holdSeconds: TimeInterval = 3) {
        self.estimator = estimator
        self.idleCeilingRpm = idleCeilingRpm
        self.crawlSpeedMps = crawlSpeedMps
        self.holdSeconds = holdSeconds
    }

    public mutating func reset() {
        gear = nil
        lastCoupledT = -.infinity
        pairs.removeAll()
        lastSpeedT = nil
        speedInterval = 0.04
    }

    /// - Parameters:
    ///   - rpmAt/speedAt: when each reading was taken. Without them every
    ///     call counts as a fresh, simultaneous pair.
    ///   - brakePercent: brake pedal, if known.
    public mutating func update(rpm: Double?, rpmAt: TimeInterval? = nil,
                                speedMps: Double?, speedAt: TimeInterval? = nil,
                                brakePercent: Double? = nil,
                                at t: TimeInterval) -> Int {
        let speed = speedMps ?? 0
        guard let rpm, rpm > 300 else {
            // Engine off or no OBD: show neutral rather than a blank.
            reset()
            return 0
        }

        if speed < crawlSpeedMps {
            // Stationary or crawling. Revs above idle while actually moving can
            // only be a launch (1st, clutch slipping); otherwise neutral/clutch-in.
            pairs.removeAll()
            let launching = rpm > idleCeilingRpm && speed >= 0.5
            gear = launching ? 1 : nil
            lastCoupledT = launching ? t : -.infinity
            return launching ? 1 : 0
        }

        let wheelRpm = speed * 60 / estimator.gearing.tireCircumferenceMeters
        let ratio = rpm / wheelRpm
        let sT = speedAt ?? t, rT = rpmAt ?? t
        if sT != lastSpeedT {
            if let prev = lastSpeedT, sT > prev, sT - prev < 5 {
                speedInterval = sT - prev
            }
            lastSpeedT = sT
            if abs(rT - sT) <= Self.pairWindow {
                pairs.append((sT, ratio))
            }
        }
        // Three speed samples' worth, never under 0.6 s: 0.6 s with the
        // 25 Hz logger, ~3.2 s with 1 Hz phone GPS.
        let window = max(Self.minWindow, 3.2 * speedInterval)
        pairs.removeAll { t - $0.t > window }

        if let coupled = coupledRatio() {
            var candidate = estimator.gear(overallRatio: coupled)
            // Clutch slipping in 1st reads as "more than 1st".
            let firstNominal = estimator.gearing.ratios[0] * estimator.gearing.finalDrive
            if candidate == nil, coupled > firstNominal * (1 + estimator.tolerance), rpm > idleCeilingRpm {
                candidate = 1
            }
            if var g = candidate {
                // Braking never moves the gear up: a higher reading here is
                // the clutch going down or the speed lagging, not a shift.
                if let current = gear, g > current, (brakePercent ?? 0) > Self.brakingPercent { g = current }
                gear = g
                lastCoupledT = t
                return g
            }
        }

        // Not coupled (clutch in, mid-shift, stale speed): keep the gear we had.
        if let gear, t - lastCoupledT <= holdSeconds { return gear }
        // Held long enough. Coasting with the clutch in / in neutral.
        if rpm <= idleCeilingRpm { return 0 }
        // Engine up, moving, nothing coupled for a while (wheelspin, or a car
        // whose gearing table is off): stay on the last gear, never a blank.
        return gear ?? 0
    }

    private func coupledRatio() -> Double? {
        guard pairs.count >= Self.pairsNeeded,
              let first = pairs.first, let last = pairs.last,
              last.t - first.t >= Self.pairSpan else { return nil }
        let values = pairs.map(\.ratio)
        guard let lo = values.min(), let hi = values.max(), lo > 0, hi / lo <= Self.pairSpread else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
