import Foundation

/// Forgotten-stop rule (R1.6): auto-stop when the OBD link has been gone AND
/// the car stationary for `threshold` (5 min). Pure logic, fed observations;
/// the recorder asks `shouldAutoStop(now:)` periodically.
///
/// Without OBD, a logger that was streaming and then went silent stands in:
/// the Micro loses power with the car (or shuts itself down when parked), so
/// its disappearance plus 5 min stationary is the same "forgotten stop". A
/// logger that keeps reporting (permanent power) never triggers it, which is
/// why its *presence* is not treated as the engine being on. On Oct 27 2026 a
/// session with no adapter ran 80 min past the drive for want of this.
///
/// Phone-only sessions (no OBD, no logger) don't auto-stop — there is no
/// signal to key on, and a parked photo stop shouldn't end a drive.
public struct AutoStopMonitor: Sendable {

    public var threshold: TimeInterval
    /// GPS speed below this (m/s) counts as stationary.
    public var stationarySpeed: Double

    private var everSawObd = false
    private var lastObdSeen: TimeInterval = 0
    private var everSawLogger = false
    private var lastLoggerSeen: TimeInterval = 0
    private var lastMovement: TimeInterval?

    public init(threshold: TimeInterval = 300, stationarySpeed: Double = 1.0) {
        self.threshold = threshold
        self.stationarySpeed = stationarySpeed
    }

    public mutating func noteObdAlive(at t: TimeInterval) {
        everSawObd = true
        lastObdSeen = t
    }

    public mutating func noteLoggerAlive(at t: TimeInterval) {
        everSawLogger = true
        lastLoggerSeen = t
    }

    public mutating func noteSpeed(_ metersPerSecond: Double, at t: TimeInterval) {
        if metersPerSecond >= stationarySpeed {
            lastMovement = t
        } else if lastMovement == nil {
            lastMovement = t // anchor: stationary since first observation
        }
    }

    public func shouldAutoStop(now: TimeInterval) -> Bool {
        if everSawObd {
            guard now - lastObdSeen >= threshold else { return false }
        } else if everSawLogger {
            guard now - lastLoggerSeen >= threshold else { return false }
        } else {
            return false
        }
        guard let lastMovement else { return false } // no GPS at all — don't guess
        return now - lastMovement >= threshold
    }
}
