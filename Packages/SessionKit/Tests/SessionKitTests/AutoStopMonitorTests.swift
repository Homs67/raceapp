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

    func testLoggerGoingSilentWhileParkedStopsASessionWithoutOBD() {
        var m = AutoStopMonitor()
        for t in stride(from: 0.0, through: 470, by: 10) {
            m.noteLoggerAlive(at: t)
            m.noteSpeed(t < 400 ? 12 : 0, at: t)
        }
        XCTAssertFalse(m.shouldAutoStop(now: 600), "logger gone only 130 s")
        m.noteSpeed(0, at: 700)
        XCTAssertTrue(m.shouldAutoStop(now: 800), "logger gone and parked for 5 min")
    }

    func testLoggerStillReportingNeverStops() {
        var m = AutoStopMonitor()
        for t in stride(from: 0.0, through: 2000, by: 10) {
            m.noteLoggerAlive(at: t)
            m.noteSpeed(0, at: t)
        }
        XCTAssertFalse(m.shouldAutoStop(now: 2000), "permanent power: present logger is no ignition signal")
    }
}
