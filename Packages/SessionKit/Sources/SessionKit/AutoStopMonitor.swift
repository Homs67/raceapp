import Foundation

/// Forgotten-stop rule (R1.6): auto-stop when the OBD link has been gone AND
/// the car stationary for `threshold` (5 min). Pure logic, fed observations;
/// the recorder asks `shouldAutoStop(now:)` periodically.
///
/// Phone-only sessions (never saw OBD) don't auto-stop — there is no
/// ignition-off signal to key on, and a parked photo stop shouldn't end a drive.
public struct AutoStopMonitor: Sendable {

    public var threshold: TimeInterval
    /// GPS speed below this (m/s) counts as stationary.
    public var stationarySpeed: Double

    private var everSawObd = false
    private var lastObdSeen: TimeInterval = 0
    private var lastMovement: TimeInterval?

    public init(threshold: TimeInterval = 300, stationarySpeed: Double = 1.0) {
        self.threshold = threshold
        self.stationarySpeed = stationarySpeed
    }

    public mutating func noteObdAlive(at t: TimeInterval) {
        everSawObd = true
        lastObdSeen = t
    }

    public mutating func noteSpeed(_ metersPerSecond: Double, at t: TimeInterval) {
        if metersPerSecond >= stationarySpeed {
            lastMovement = t
        } else if lastMovement == nil {
            lastMovement = t // anchor: stationary since first observation
        }
    }

    public func shouldAutoStop(now: TimeInterval) -> Bool {
        guard everSawObd else { return false }
        guard now - lastObdSeen >= threshold else { return false }
        guard let lastMovement else { return false } // no GPS at all — don't guess
        return now - lastMovement >= threshold
    }
}
