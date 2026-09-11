import XCTest
@testable import RaceBoxKit

/// Bytes captured from a real RaceBox Micro (serial 3242708836, hardware 1.4,
/// firmware 3.5) on 2026-09-10 over CoreBluetooth. The golden vectors in
/// `RaceBoxProtocolTests` prove we match the specification; these prove we
/// match the actual device, which is not quite the same claim.
final class RaceBoxHardwareCaptureTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt8($0, radix: 16) }
    }

    /// Captured with a 3D fix, 12 satellites, sitting still on a desk on USB power.
    private let liveFix = """
        B5 62 FF 01 50 00 78 BA C1 1A EA 07 09 0B 04 29 19 37 16 00 00 00 45 AB
        A8 2F 03 01 EA 0C 2E 81 6B B9 60 E9 47 14 90 2F 00 00 0F B0 00 00 D4 01
        00 00 AF 03 00 00 08 00 00 00 C4 57 05 02 6E 00 00 00 20 EB 42 00 91 00
        00 34 F8 FF 01 00 D2 03 EF FF 7C 00 B0 FF C2 A4
        """

    /// The very first message after connecting — receiver still cold, so the
    /// coordinates are meaningless and accuracy is ±103 km.
    private let coldStart = """
        B5 62 FF 01 50 00 28 7E C1 1A EA 07 09 0B 04 29 0A 37 26 5D 00 00 05 E4
        6E 15 00 00 26 00 7F 86 6B B9 67 E9 47 14 58 45 00 00 D7 C5 00 00 FD 6F
        57 00 DE D3 3D 00 00 00 00 00 00 00 00 00 20 4E 00 00 80 A8 12 01 0F 27
        00 34 F9 FF 00 00 D5 03 F0 FF 7C 00 B1 FF 15 29
        """

    /// Reply to our `0xFF 0x22` request — empty memory, security off.
    private let recordingStatusReply = "B5 62 FF 22 0C 00 00 00 02 00 00 00 00 00 00 00 03 00 32 B0"

    func testRealDeviceFixDecodes() throws {
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes(liveFix))).first)
        XCTAssertEqual(parser.checksumFailures, 0)
        XCTAssertEqual(packet.kind, .liveData)

        let m = try XCTUnwrap(RaceBoxDataMessage(payload: packet.payload))
        XCTAssertTrue(m.hasValidFix)
        XCTAssertEqual(m.fixStatus, .threeD)
        XCTAssertEqual(m.satellites, 12)
        XCTAssertTrue(m.coordinatesValid)

        // Los Angeles, on a desk. Sanity-bounded rather than exact so the test
        // documents the location without pinning a home address precisely.
        XCTAssertEqual(m.latitude, 34.0257, accuracy: 0.01)
        XCTAssertEqual(m.longitude, -118.4137, accuracy: 0.01)
        XCTAssertLessThan(m.horizontalAccuracy, 1.0)       // ±0.47 m
        XCTAssertEqual(m.pdop, 1.45, accuracy: 0.01)

        // Stationary
        XCTAssertLessThan(m.speedMps, 0.5)
        // Lying flat: gravity almost entirely on Z
        XCTAssertEqual(m.gForce.z, 0.978, accuracy: 0.005)
        XCTAssertEqual(m.gForce.magnitude, 0.978, accuracy: 0.01)

        // 2026-09-11 04:41 UTC
        let parts = Calendar.utc.dateComponents([.year, .month, .day],
                                                from: try XCTUnwrap(m.timestamp))
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 11)
    }

    /// Cold-start garbage must be rejected by the flags, not by a plausibility
    /// guess — this packet carries a confident-looking lat/lon that is wrong.
    func testColdStartPacketIsRejectedByItsFlags() throws {
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes(coldStart))).first)
        let m = try XCTUnwrap(RaceBoxDataMessage(payload: packet.payload))

        XCTAssertFalse(m.hasValidFix, "no fix yet — every consumer must gate on this")
        XCTAssertEqual(m.fixStatus, .none)
        XCTAssertEqual(m.satellites, 0)
        XCTAssertGreaterThan(m.horizontalAccuracy, 1000, "±103 km of uncertainty")
        XCTAssertEqual(m.pdop, 99.99, accuracy: 0.01)
        // It still reports coordinates, which is exactly the trap.
        XCTAssertNotEqual(m.latitude, 0)
    }

    /// The Micro reports input voltage, and on USB bench power that is ~5 V —
    /// not the 12 V it sees in a car. Both are healthy; only the car range is
    /// meaningful as a fault check.
    func testMicroOnUsbPowerReportsFiveVolts() throws {
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes(liveFix))).first)
        let m = try XCTUnwrap(RaceBoxDataMessage(payload: packet.payload))
        XCTAssertEqual(m.powerByte, 0x34)
        XCTAssertEqual(m.power(for: .micro), .inputVoltage(5.2))
    }

    func testRealRecordingStatusReplyDecodes() throws {
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes(recordingStatusReply))).first)
        XCTAssertEqual(parser.checksumFailures, 0)

        let status = try XCTUnwrap(RaceBoxRecordingStatus(payload: packet.payload))
        XCTAssertFalse(status.isRecording)
        XCTAssertEqual(status.memoryLevelPercent, 0)
        XCTAssertEqual(status.storedMessages, 0)
        XCTAssertEqual(status.memorySizeMessages, 196_608, "matches the documented capacity")
        XCTAssertFalse(status.securityEnabled)
        XCTAssertTrue(status.memoryUnlocked)

        // Empty memory at 25 Hz ≈ 2 h 11 min of recording
        let remaining = try XCTUnwrap(status.remainingSeconds(at: .hz25))
        XCTAssertEqual(remaining / 60, 131, accuracy: 1)
    }

    /// Firmware 3.5 is past every 3.3 capability gate.
    func testCapturedDeviceInfoUnlocksAllFeatures() {
        let info = RaceBoxDeviceInfo(deviceInfo: [
            .model: "RaceBox Micro                 ",   // device pads these
            .serialNumber: "3242708836          ",
            .firmwareRevision: "3.5 ",
            .hardwareRevision: "1.4",
            .manufacturer: "RaceBox Motorsport LLC ",
        ])
        XCTAssertEqual(info.model, .micro)
        XCTAssertEqual(info.serialNumber, "3242708836")
        XCTAssertEqual(info.firmware, RaceBoxFirmware(major: 3, minor: 5))
        XCTAssertTrue(info.supportsStandaloneRecording)
        XCTAssertTrue(info.supportsGnssConfig)
        XCTAssertTrue(info.supports20HzRecording)
        XCTAssertEqual(info.displayName, "RaceBox Micro 3242708836")
    }

    /// Both captured packets back to back, as the link actually delivers them.
    func testBackToBackRealPacketsParseCleanly() {
        var blob = Data(bytes(coldStart))
        blob.append(Data(bytes(liveFix)))
        blob.append(Data(bytes(recordingStatusReply)))
        var parser = RaceBoxPacketParser()
        let packets = parser.feed(blob)
        XCTAssertEqual(packets.map(\.kind), [.liveData, .liveData, .recordingStatus])
        XCTAssertEqual(parser.checksumFailures, 0)
        XCTAssertEqual(parser.bytesDiscarded, 0)
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
