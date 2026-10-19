import XCTest
@testable import SessionKit

final class LoggerPowerTests: XCTestCase {

    /// The Micro on the car's OBD port.
    func testVehicleSupplyIsNotAChargeReading() {
        guard case .supply(let v, .vehicle, let low) = LoggerPower.from(inputVolts: 12.4) else {
            return XCTFail("12.4 V is the car")
        }
        XCTAssertEqual(v, 12.4, accuracy: 0.001)
        XCTAssertFalse(low)
        XCTAssertEqual(LoggerPower.from(inputVolts: 12.4).shortText, "12.4 V")
    }

    func testFlatCarBatteryIsFlagged() {
        XCTAssertTrue(LoggerPower.from(inputVolts: 11.4).needsAttention)
    }

    /// The measured case: a boost converter holding 5.1 V says nothing about
    /// the cell behind it, so no percentage may be invented.
    func testRegulatedFiveVoltRailReportsNoPercentage() {
        let power = LoggerPower.from(inputVolts: 5.1)
        guard case .supply(_, .usb, let low) = power else { return XCTFail("5.1 V is a USB rail") }
        XCTAssertFalse(low)
        XCTAssertEqual(power.shortText, "5.1 V")
        XCTAssertFalse(power.shortText.contains("%"), "never implies a charge level")
        XCTAssertNotNil(power.explanation)
    }

    /// A boost dropping out of regulation is the only warning that setup gives.
    func testSaggingRailIsFlagged() {
        let power = LoggerPower.from(inputVolts: 4.6)
        XCTAssertTrue(power.needsAttention)
        XCTAssertEqual(power.explanation?.contains("close to empty"), true)
    }

    /// Wired straight to one cell, voltage does map to charge.
    func testDirectCellMapsToApproximateCharge() {
        guard case .cell(_, let full) = LoggerPower.from(inputVolts: 4.2) else { return XCTFail("cell") }
        XCTAssertEqual(full, 100)
        guard case .cell(_, let mid) = LoggerPower.from(inputVolts: 3.84) else { return XCTFail("cell") }
        XCTAssertEqual(mid, 50, accuracy: 2)
        guard case .cell(_, let low) = LoggerPower.from(inputVolts: 3.68) else { return XCTFail("cell") }
        XCTAssertEqual(low, 10, accuracy: 2)
        XCTAssertTrue(LoggerPower.from(inputVolts: 3.68).needsAttention)
    }

    func testCellCurveIsMonotonic() {
        var previous = -1
        for millivolts in stride(from: 3300, through: 4200, by: 10) {
            let percent = LoggerPower.cellPercent(volts: Double(millivolts) / 1000)
            XCTAssertGreaterThanOrEqual(percent, previous, "charge never falls as voltage rises")
            previous = percent
        }
        XCTAssertEqual(previous, 100)
    }

    /// A Mini reports a real battery level; that path must stay untouched.
    func testDeviceBatteryPassesThrough() {
        let power = LoggerPower.battery(percent: 82, charging: true)
        XCTAssertEqual(power.shortText, "82% ⚡︎")
        XCTAssertFalse(power.needsAttention)
        XCTAssertTrue(LoggerPower.battery(percent: 9, charging: false).needsAttention)
    }
}
