import XCTest
@testable import ObdKit

final class CanSignalTests: XCTestCase {

    private func signal(_ key: String) -> CanSignal {
        CanSignalMap.mazdaND.first { $0.key == key }!
    }

    // MARK: - ND decoders

    func testSteeringAngleCentered() {
        // raw u16 = 16000 → 0°; 15000 → +100° (right); 17000 → −100° (left)
        XCTAssertEqual(signal("steeringAngle").decode([0x3E, 0x80]) ?? .nan, 0, accuracy: 0.01)   // 0x3E80 = 16000
        XCTAssertEqual(signal("steeringAngle").decode([0x3A, 0x98]) ?? .nan, 100, accuracy: 0.01) // 15000
        XCTAssertEqual(signal("steeringAngle").decode([0x42, 0x68]) ?? .nan, -100, accuracy: 0.01)// 17000
    }

    func testAcceleratorPedal() {
        // byte[4] / 2.5 → 0xFA (250) = 100%
        XCTAssertEqual(signal("accelPedal").decode([0, 0, 0, 0, 0xFA]) ?? .nan, 100, accuracy: 0.01)
        XCTAssertEqual(signal("accelPedal").decode([0, 0, 0, 0, 0]) ?? .nan, 0, accuracy: 0.01)
        XCTAssertNil(signal("accelPedal").decode([0, 0, 0, 0])) // too short
    }

    func testRpmFromCan() {
        // u16/4 → 0x1F40 = 8000 → 2000 rpm
        XCTAssertEqual(signal("canRpm").decode([0x1F, 0x40]) ?? .nan, 2000, accuracy: 0.01)
    }

    func testBrakeBitField() {
        // brake = min(max(bitsToUInt(raw,28,12) − 156, 0)/2.56, 100)
        // Build 8 bytes with a 12-bit field starting at bit 28 = 156 → 0%
        func brakeFrame(_ raw12: UInt32) -> [UInt8] {
            var bits = [Bool](repeating: false, count: 64)
            for i in 0..<12 where (raw12 & (1 << (11 - i))) != 0 { bits[28 + i] = true }
            var bytes = [UInt8](repeating: 0, count: 8)
            for (i, set) in bits.enumerated() where set { bytes[i / 8] |= UInt8(0x80) >> (i % 8) }
            return bytes
        }
        XCTAssertEqual(signal("brakePos").decode(brakeFrame(156)) ?? .nan, 0, accuracy: 0.01)
        XCTAssertEqual(signal("brakePos").decode(brakeFrame(156 + 256)) ?? .nan, 100, accuracy: 0.01)
        XCTAssertEqual(signal("brakePos").decode(brakeFrame(100)) ?? .nan, 0, accuracy: 0.01) // clamped ≥0
    }

    // MARK: - Frame parser

    func testParseSpacedFrame() {
        let frame = CanFrameParser.parse("086 3E 80 12 34")
        XCTAssertEqual(frame?.id, 0x086)
        XCTAssertEqual(frame?.data, [0x3E, 0x80, 0x12, 0x34])
    }

    func testParseUnspacedFrame() {
        // 11-bit ID (3 nibbles) + 4 data bytes (8 nibbles) = 11 hex chars
        let frame = CanFrameParser.parse("2021F40000A")
        XCTAssertEqual(frame?.id, 0x202)
        XCTAssertEqual(frame?.data, [0x1F, 0x40, 0x00, 0x0A])
    }

    func testParserRejectsNoise() {
        XCTAssertNil(CanFrameParser.parse("BUFFER FULL"))
        XCTAssertNil(CanFrameParser.parse("STOPPED"))
        XCTAssertNil(CanFrameParser.parse(">"))
        XCTAssertNil(CanFrameParser.parse(""))
        XCTAssertNil(CanFrameParser.parse("OK"))
    }

    func testWheelSpeed() {
        // Four u16 words (FL FR RL RR), (raw − 10000)·0.01 km/h each, averaged.
        // Standstill: all wheels 10000 (0x2710) → exactly 0.
        let still: [UInt8] = [0x27, 0x10, 0x27, 0x10, 0x27, 0x10, 0x27, 0x10]
        XCTAssertEqual(signal("wheelSpeed").decode(still) ?? .nan, 0, accuracy: 0.001)
        // All wheels 11000 (0x2AF8) → 10 km/h
        let rolling: [UInt8] = [0x2A, 0xF8, 0x2A, 0xF8, 0x2A, 0xF8, 0x2A, 0xF8]
        XCTAssertEqual(signal("wheelSpeed").decode(rolling) ?? .nan, 10, accuracy: 0.001)
        // Mixed: two wheels at 0, two at 10 → 5 km/h average
        let mixed: [UInt8] = [0x27, 0x10, 0x2A, 0xF8, 0x27, 0x10, 0x2A, 0xF8]
        XCTAssertEqual(signal("wheelSpeed").decode(mixed) ?? .nan, 5, accuracy: 0.001)
        XCTAssertNil(signal("wheelSpeed").decode([0x27, 0x10, 0x27, 0x10])) // too short
    }

    func testFrameIDsDeduplicated() {
        // 0x202 appears in two signals (accel, rpm) → one filter ID
        let ids = CanSignalMap.frameIDs(CanSignalMap.mazdaND)
        XCTAssertEqual(Set(ids), [0x086, 0x078, 0x202, 0x4B0])
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: - Monitor session end-to-end (replay transport)

    func testMonitorDecodesSignals() async {
        // ATCF 086 → then ATMA streams two steering frames; 202 → accel frame.
        let transport = ReplayTransport(responses: [
            "ATZ": ["ELM327 v2.2"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS1": ["OK"],
            "ATH1": ["OK"], "ATCAF0": ["OK"], "ATSP6": ["OK"], "ATCM 7FF": ["OK"],
            "ATCM 000": ["OK"],
            "ATCF 086": ["OK"], "ATCF 078": ["OK"], "ATCF 202": ["OK"],
            // Monitor output for each filtered ID (the sticky last response repeats)
            "ATMA": ["086 3E 80 00 00\r086 3A 98 00 00"],
        ])
        let session = CanMonitorSession(transport: transport)
        await session.configure()
        let report = await session.monitor(signals: CanSignalMap.mazdaND, perID: .milliseconds(120))

        let steering = report.signals.first { $0.key == "steeringAngle" }
        XCTAssertNotNil(steering?.value) // last steering frame decoded
        XCTAssertGreaterThan(report.frames.first { $0.id == 0x086 }?.count ?? 0, 0)
    }

    func testScanRestartsAfterBufferFull() async {
        // Real driveway capture: open-filter ATMA dies at BUFFER FULL after
        // ~350 ms. The scan must re-arm ATMA and keep accumulating frames.
        let transport = ReplayTransport(responses: [
            "ATCM 000": ["OK"],
            "ATMA": ["086 3E 80 00 00\r4B0 27 10 27 10 27 10 27 10\rBUFFER FULL"],
        ])
        let session = CanMonitorSession(transport: transport)
        let report = await session.scanBus(duration: .milliseconds(700))

        let atmaCount = transport.sentCommands.filter { $0 == "ATMA" }.count
        XCTAssertGreaterThanOrEqual(atmaCount, 2, "should re-arm ATMA after BUFFER FULL")
        XCTAssertGreaterThanOrEqual(report.frames.first { $0.id == 0x086 }?.count ?? 0, 2,
                                    "frames from post-restart bursts must accumulate")
    }
}
