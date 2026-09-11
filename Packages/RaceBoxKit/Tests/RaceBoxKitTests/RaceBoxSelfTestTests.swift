import XCTest
@testable import RaceBoxKit

final class RaceBoxSelfTestTests: XCTestCase {

    private func message(speedMps: Double = 0,
                         g: RaceBoxVector3 = RaceBoxVector3(x: 0, y: 0, z: 1),
                         rotation: RaceBoxVector3 = RaceBoxVector3(x: 0, y: 0, z: 0),
                         hasFix: Bool = true,
                         satellites: Int = 12,
                         date: Date = Date(),
                         powerByte: UInt8? = nil) -> RaceBoxDataMessage {
        let sample = RaceBoxSample(speedMps: speedMps, gForce: g, rotationRate: rotation,
                                   satellites: satellites, hasFix: hasFix, date: date)
        let packet = RaceBoxEncoder.dataMessage(sample, model: .micro, powerByte: powerByte)
        return RaceBoxDataMessage(payload: packet.payload)!
    }

    private func healthyStats() -> RaceBoxLinkStats {
        var stats = RaceBoxLinkStats()
        stats.measuredHz = 25
        stats.packetsParsed = 250
        stats.dataMessages = 250
        return stats
    }

    private func status(_ checks: [RaceBoxSelfTest.Check], _ id: String) -> RaceBoxSelfTest.Status? {
        checks.first { $0.id == id }?.status
    }

    func testHealthyStationaryDevicePassesEverything() {
        let checks = RaceBoxSelfTest.evaluate(messages: [message()], stats: healthyStats(),
                                              model: .micro)
        let summary = RaceBoxSelfTest.summary(checks)
        XCTAssertEqual(summary.failed, 0, "unexpected failures: \(checks.filter { $0.status == .fail }.map(\.title))")
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertGreaterThanOrEqual(summary.passed, 8)
    }

    func testNoDataIsASingleClearFailure() {
        let checks = RaceBoxSelfTest.evaluate(messages: [], stats: RaceBoxLinkStats(), model: .micro)
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.status, .fail)
    }

    func testLowRateAndChecksumErrorsFail() {
        var stats = healthyStats()
        stats.measuredHz = 12
        stats.checksumFailures = 3
        stats.bytesDiscarded = 40
        let checks = RaceBoxSelfTest.evaluate(messages: [message()], stats: stats, model: .micro)
        XCTAssertEqual(status(checks, "rate"), .fail)
        XCTAssertEqual(status(checks, "checksum"), .fail)
        XCTAssertEqual(status(checks, "framing"), .fail)
    }

    func testAtRestChecksAreSkippedWhileMoving() {
        // Gravity/gyro assertions are meaningless under cornering load.
        let moving = message(speedMps: 30,
                             g: RaceBoxVector3(x: 0.4, y: 0.9, z: 1.0),
                             rotation: RaceBoxVector3(x: 0, y: 0, z: 25))
        let checks = RaceBoxSelfTest.evaluate(messages: [moving], stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "gravity"), .skipped)
        XCTAssertEqual(status(checks, "gyro"), .skipped)
        XCTAssertEqual(status(checks, "fix"), .pass)
    }

    func testBadMountOrientationStillSeesOneG() {
        // Axis assignment depends on how the Micro sits in the OBD port, so the
        // check must be on magnitude, not on Z alone.
        let sideways = message(g: RaceBoxVector3(x: 0.99, y: 0, z: 0.05))
        let checks = RaceBoxSelfTest.evaluate(messages: [sideways], stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "gravity"), .pass)
    }

    func testMissingGravityFails() {
        let checks = RaceBoxSelfTest.evaluate(messages: [message(g: RaceBoxVector3(x: 0, y: 0, z: 0.2))],
                                              stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "gravity"), .fail)
    }

    func testDriftingGyroAtRestFails() {
        let checks = RaceBoxSelfTest.evaluate(
            messages: [message(rotation: RaceBoxVector3(x: 0, y: 0, z: 30))],
            stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "gyro"), .fail)
    }

    func testNoFixSkipsPositionChecks() {
        let checks = RaceBoxSelfTest.evaluate(messages: [message(hasFix: false, satellites: 2)],
                                              stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "fix"), .fail)
        XCTAssertEqual(status(checks, "accuracy"), .skipped)
        XCTAssertEqual(status(checks, "position"), .skipped)
    }

    func testClockSkewIsCaught() {
        // Device reporting a time three minutes off the phone — exactly the
        // class of error that silently ruins video sync.
        let skewed = message(date: Date().addingTimeInterval(-180))
        let checks = RaceBoxSelfTest.evaluate(messages: [skewed], stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(checks, "clock"), .fail)
    }

    func testMicroVoltageRangeVersusMiniBattery() {
        // 0x79 = 12.1 V on a Micro (healthy) but reads as 121 % on a Mini.
        let micro = RaceBoxSelfTest.evaluate(messages: [message(powerByte: 0x79)],
                                             stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(micro, "power"), .pass)

        // 0x28 = 4.0 V — engine off, dying battery.
        let lowVoltage = RaceBoxSelfTest.evaluate(messages: [message(powerByte: 0x28)],
                                                  stats: healthyStats(), model: .micro)
        XCTAssertEqual(status(lowVoltage, "power"), .fail)

        let flatMini = RaceBoxSelfTest.evaluate(messages: [message(powerByte: 0)],
                                                stats: healthyStats(), model: .miniS)
        XCTAssertEqual(status(flatMini, "power"), .fail)
    }

    func testPowerCheckOmittedWhenModelUnknown() {
        let checks = RaceBoxSelfTest.evaluate(messages: [message()], stats: healthyStats(), model: nil)
        XCTAssertNil(status(checks, "power"), "can't judge the power byte without knowing the model")
    }
}
