import Foundation

/// What the gear widget shows, built on `GearEstimator`'s stateless ratio
/// match with the context a human uses: a car that sits at idle is in
/// neutral (or clutch-in, which looks the same), a car crawling away with the
/// engine above idle is launching in 1st even while the clutch slips, and a
/// gear doesn't vanish for the half-second the ratio is unresolved mid-shift.
///
/// On the Oct 19 2026 drive the bare estimator answered nothing 55% of the
/// time — 85 s, 61 s, 51 s and 30 s stretches at traffic lights, plus a hole
/// on every shift. This turns those into "N", "1" and the previous gear.
///
/// Reverse is deliberately not detected. The ND2's reverse ratio sits where a
/// slipping clutch in 2nd also lands, and a speed-change-versus-G detector was
/// tried on real drives (Oct 2026) and misread parking manoeuvres often
/// enough to be worse than nothing.
///
/// Result: `nil` = no engine data at all (show "—"); `0` = neutral;
/// `1...` = gear.
public struct GearTracker: Sendable {

    public let estimator: GearEstimator
    /// Below this the engine is idling, whatever the pedal does next.
    public let idleCeilingRpm: Double
    /// Below this the car is stationary or crawling; the speed/RPM ratio is
    /// meaningless here (clutch slip, GPS noise), so context decides.
    public let crawlSpeedMps: Double
    /// Keep the last resolved gear this long when the ratio stops matching
    /// while moving — a shift, or a moment of clutch slip.
    public let holdSeconds: TimeInterval

    private var lastGear: Int?
    private var lastMatchT: TimeInterval = -.infinity

    public init(estimator: GearEstimator = GearEstimator(),
                idleCeilingRpm: Double = 1250,
                crawlSpeedMps: Double = 2,
                holdSeconds: TimeInterval = 2) {
        self.estimator = estimator
        self.idleCeilingRpm = idleCeilingRpm
        self.crawlSpeedMps = crawlSpeedMps
        self.holdSeconds = holdSeconds
    }

    public mutating func reset() {
        lastGear = nil
        lastMatchT = -.infinity
    }

    public mutating func update(rpm: Double?, speedMps: Double?, at t: TimeInterval) -> Int? {
        let speed = speedMps ?? 0
        guard let rpm, rpm > 300 else {
            // Engine off or no OBD: nothing to say.
            reset()
            return nil
        }

        if speed < crawlSpeedMps {
            // Stationary or crawling. Revs above idle while actually moving can
            // only be a launch (1st, clutch slipping); otherwise neutral/clutch-in.
            let launching = rpm > idleCeilingRpm && speed >= 0.5
            lastGear = launching ? 1 : nil
            lastMatchT = launching ? t : -.infinity
            return launching ? 1 : 0
        }

        if let gear = estimator.gear(rpm: rpm, speedMps: speed) {
            lastGear = gear
            lastMatchT = t
            return gear
        }

        // Moving, ratio unresolved. Clutch slip in 1st reads as "more than 1st".
        let wheelRpm = speed * 60 / estimator.gearing.tireCircumferenceMeters
        let firstNominal = estimator.gearing.ratios[0] * estimator.gearing.finalDrive
        if rpm / wheelRpm > firstNominal * (1 + estimator.tolerance), rpm > idleCeilingRpm {
            lastGear = 1
            lastMatchT = t
            return 1
        }

        if let lastGear, t - lastMatchT <= holdSeconds {
            return lastGear            // mid-shift: keep showing the gear we left
        }
        // Held long enough. Coasting with the clutch in / in neutral.
        if rpm <= idleCeilingRpm { return 0 }
        // Engine up, moving, no ratio for a while (sustained wheelspin, or a
        // car whose gearing table is off): stay on the last gear rather than
        // flash a blank. The next clean match corrects it.
        return lastGear
    }
}
