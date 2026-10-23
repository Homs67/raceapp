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
/// Reverse is a direction, not a ratio: its overall ratio on the ND2 sits
/// between 1st and 2nd, exactly where a slipping clutch in 2nd also lands, so
/// it is never called from RPM alone. `DirectionSense` watches the physics
/// instead — a car whose speed rises while its longitudinal G points backwards
/// is reversing — and the tracker shows R whenever that says so and the car
/// is moving.
///
/// Result: `nil` = no engine data at all (show "—"); `0` = neutral;
/// `-1` = reverse; `1...` = gear.
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
    private var direction = DirectionSense()

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
        direction = DirectionSense()
    }

    /// - Parameter longG: car-frame longitudinal G, + = forward, from a
    ///   calibrated source. Pass nil when there isn't one; reverse is then
    ///   never shown.
    public mutating func update(rpm: Double?, speedMps: Double?, longG: Double? = nil,
                                at t: TimeInterval) -> Int? {
        let speed = speedMps ?? 0
        direction.update(speedMps: speed, longG: longG, at: t)

        guard let rpm, rpm > 300 else {
            // Engine off or no OBD: nothing to say.
            lastGear = nil
            lastMatchT = -.infinity
            return nil
        }

        if direction.isReversing, speed >= DirectionSense.stationaryBelow {
            lastGear = nil
            lastMatchT = -.infinity
            return -1
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

/// Which way the car is moving, from the sign agreement between speed change
/// and longitudinal G over short windows. Only judged below 3 m/s (reverse
/// territory on a road car); faster than 4 m/s is forward by definition.
/// Standing still for 1.5 s forgets the verdict, so every move-off is judged
/// afresh — a reverse out of a space followed by a forward launch reads R
/// then 1. Verified against a real drive's parking manoeuvres; it needs a
/// calibrated car-frame G, so phone-only sessions never report reverse.
public struct DirectionSense: Sendable {
    public static let stationaryBelow = 0.3
    static let judgeBelow = 3.0
    static let forwardAbove = 4.0
    static let window: TimeInterval = 0.8
    static let minSpeedChange = 0.25
    static let minMeanG = 0.04
    static let forgetAfterStationary: TimeInterval = 1.5

    private var history: [(t: TimeInterval, speed: Double, g: Double)] = []
    private var score = 0
    private var stoppedSince: TimeInterval?
    public private(set) var isReversing = false

    public init() {}

    public mutating func update(speedMps: Double, longG: Double?, at t: TimeInterval) {
        if speedMps < Self.stationaryBelow {
            history.removeAll()
            if let stoppedSince {
                if t - stoppedSince > Self.forgetAfterStationary {
                    score = 0
                    isReversing = false
                }
            } else {
                stoppedSince = t
            }
            return
        }
        stoppedSince = nil
        if speedMps >= Self.forwardAbove {
            score = 4
            isReversing = false
            history.removeAll()
            return
        }
        guard speedMps < Self.judgeBelow, let longG else { return }
        history.append((t, speedMps, longG))
        history.removeAll { t - $0.t > Self.window }
        guard history.count >= 5, let first = history.first, t - first.t >= 0.6 else { return }
        let dv = speedMps - first.speed
        let meanG = history.reduce(0) { $0 + $1.g } / Double(history.count)
        guard abs(dv) >= Self.minSpeedChange, abs(meanG) >= Self.minMeanG else { return }
        let agree = (dv > 0) == (meanG > 0)
        score = max(-4, min(4, score + (agree ? 1 : -1)))
        if score <= -2 { isReversing = true } else if score >= 1 { isReversing = false }
    }
}
