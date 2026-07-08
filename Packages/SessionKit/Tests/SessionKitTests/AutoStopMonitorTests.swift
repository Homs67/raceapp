import XCTest
@testable import SessionKit

final class AutoStopMonitorTests: XCTestCase {

    func testFiresWhenObdGoneAndStationary() {
        var monitor = AutoStopMonitor()
        monitor.noteObdAlive(at: 100)
        monitor.noteSpeed(15, at: 100)  // driving
        monitor.noteSpeed(0.2, at: 110) // parked
        XCTAssertFalse(monitor.shouldAutoStop(now: 300), "not 5 min yet")
        XCTAssertTrue(monitor.shouldAutoStop(now: 411), "OBD 311s silent, stationary 301s")
    }

    func testMovementResetsClock() {
        var monitor = AutoStopMonitor()
        monitor.noteObdAlive(at: 100)
        monitor.noteSpeed(0, at: 100)
        monitor.noteSpeed(20, at: 350) // rolled away (e.g. towed / OBD died while driving)
        XCTAssertFalse(monitor.shouldAutoStop(now: 420), "moved recently — don't stop")
    }

    func testObdStillAliveBlocksAutoStop() {
        var monitor = AutoStopMonitor()
        monitor.noteSpeed(0, at: 100)
        monitor.noteObdAlive(at: 100)
        monitor.noteObdAlive(at: 390) // idling in the paddock, ignition on
        XCTAssertFalse(monitor.shouldAutoStop(now: 410))
    }

    func testNeverFiresWithoutObd() {
        var monitor = AutoStopMonitor()
        monitor.noteSpeed(0, at: 0)
        XCTAssertFalse(monitor.shouldAutoStop(now: 100_000))
    }

    func testNeverFiresWithoutGps() {
        var monitor = AutoStopMonitor()
        monitor.noteObdAlive(at: 0)
        XCTAssertFalse(monitor.shouldAutoStop(now: 100_000), "no movement signal — don't guess")
    }
}
