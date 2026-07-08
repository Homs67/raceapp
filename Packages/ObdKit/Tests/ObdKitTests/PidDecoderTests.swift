import XCTest
@testable import ObdKit

final class PidDecoderTests: XCTestCase {

    // MARK: - Single-PID decode

    func testRpm() {
        // 0x1AF8 = 6904 / 4 = 1726 rpm
        let values = PidDecoder.decodeMode01(lines: ["410C1AF8"])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].pid, 0x0C)
        XCTAssertEqual(values[0].value, 1726, accuracy: 0.001)
    }

    func testSpeed() {
        let values = PidDecoder.decodeMode01(lines: ["410D3C"])
        XCTAssertEqual(values[0].value, 60)
    }

    func testThrottle() {
        // 0x5A = 90 * 100/255 = 35.29%
        let values = PidDecoder.decodeMode01(lines: ["41115A"])
        XCTAssertEqual(values[0].value, 35.29, accuracy: 0.01)
    }

    func testCoolantTemp() {
        // 0x7B = 123 - 40 = 83°C
        let values = PidDecoder.decodeMode01(lines: ["41057B"])
        XCTAssertEqual(values[0].value, 83)
    }

    func testFuelLevel() {
        // 0x66 = 102 * 100/255 = 40%
        let values = PidDecoder.decodeMode01(lines: ["412F66"])
        XCTAssertEqual(values[0].value, 40, accuracy: 0.01)
    }

    func testControlModuleVoltage() {
        // 0x3039 = 12345 / 1000 = 12.345 V
        let values = PidDecoder.decodeMode01(lines: ["41423039"])
        XCTAssertEqual(values[0].value, 12.345, accuracy: 0.0001)
    }

    func testTimingAdvance() {
        // 0x80 = 128 / 2 - 64 = 0°
        let values = PidDecoder.decodeMode01(lines: ["410E80"])
        XCTAssertEqual(values[0].value, 0)
    }

    func testBarometricPressure() {
        let values = PidDecoder.decodeMode01(lines: ["413365"])
        XCTAssertEqual(values[0].value, 101)
    }

    // MARK: - Multi-PID responses (CAN fast loop)

    func testMultiPidSingleFrame() {
        // RPM 1726, speed 60 km/h, throttle 0x45 = 27.06%
        let values = PidDecoder.decodeMode01(lines: ["410C1AF80D3C1145"])
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0].pid, 0x0C)
        XCTAssertEqual(values[0].value, 1726, accuracy: 0.001)
        XCTAssertEqual(values[1].pid, 0x0D)
        XCTAssertEqual(values[1].value, 60)
        XCTAssertEqual(values[2].pid, 0x11)
        XCTAssertEqual(values[2].value, 27.06, accuracy: 0.01)
    }

    func testMultiFrameResponseWithLineIndices() {
        // ISO-TP multi-frame formatting: length header + "N:" line prefixes
        let lines = ["00A", "0:410C1AF80D3C", "1:114542303 9"]
        let values = PidDecoder.decodeMode01(lines: lines)
        XCTAssertEqual(values.map(\.pid), [0x0C, 0x0D, 0x11, 0x42])
    }

    func testToleratesSpaces() {
        let values = PidDecoder.decodeMode01(lines: ["41 0C 1A F8"])
        XCTAssertEqual(values[0].value, 1726, accuracy: 0.001)
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(PidDecoder.decodeMode01(lines: ["NODATA"]).isEmpty)
        XCTAssertTrue(PidDecoder.decodeMode01(lines: []).isEmpty)
        XCTAssertTrue(PidDecoder.decodeMode01(lines: ["7F0112"]).isEmpty) // negative response
    }

    // MARK: - Supported-PID bitmaps

    func testSupportedPidBitmap() {
        // 0xBE3EA813 for base 0x00
        let bytes: [UInt8] = [0xBE, 0x3E, 0xA8, 0x13]
        let pids = PidDecoder.supportedPids(basePid: 0x00, bytes: bytes)
        // 0xBE = 10111110 → PIDs 01, 03, 04, 05, 06, 07
        XCTAssertTrue(pids.contains(0x01))
        XCTAssertFalse(pids.contains(0x02))
        XCTAssertTrue(pids.contains(0x05))
        // 0x3E = 00111110 → PIDs 0B, 0C, 0D, 0E, 0F
        XCTAssertTrue(pids.contains(0x0C))
        XCTAssertTrue(pids.contains(0x0D))
        XCTAssertFalse(pids.contains(0x10))
        // 0x13 = 00010011 → PIDs 1C, 1F, 20
        XCTAssertTrue(pids.contains(0x20)) // next-range marker
    }

    // MARK: - VIN

    func testVinDecode() {
        // "1G1JC5444R7252367" over ISO-TP frames, ATS0 style
        let lines = [
            "014",
            "0:490201314731",
            "1:4A433534343452",
            "2:37323532333637",
        ]
        XCTAssertEqual(PidDecoder.decodeVin(lines: lines), "1G1JC5444R7252367")
    }

    func testVinTooShortReturnsNil() {
        XCTAssertNil(PidDecoder.decodeVin(lines: ["49020131"]))
    }

    // MARK: - DTC status

    func testDtcStatusMilOnWithOneCode() {
        // A = 0x81 → MIL on, 1 stored code
        let status = PidDecoder.decodeDtcStatus(lines: ["410181076504"])
        XCTAssertEqual(status?.milOn, true)
        XCTAssertEqual(status?.dtcCount, 1)
    }

    func testDtcStatusClean() {
        let status = PidDecoder.decodeDtcStatus(lines: ["410100076504"])
        XCTAssertEqual(status?.milOn, false)
        XCTAssertEqual(status?.dtcCount, 0)
    }
}
