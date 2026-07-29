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

    func testRotationScheduleFavorsRpmFrame() {
        let schedule = CanMonitorSession.rotationSchedule(for: CanSignalMap.mazdaND)
        // 0x202 (rpm/pedal) every other slot; every frame ID still present.
        XCTAssertEqual(schedule, [0x202, 0x086, 0x202, 0x078, 0x202, 0x4B0])
    }

    func testStreamDecodesRotationAndInterlude() async {
        // ATMA replays a mixed burst; each rotation slot keeps only its filtered
        // ID. interludeEvery 0 → slow-PID poll after the first slot.
        let transport = ReplayTransport(responses: [
            "ATZ": ["ELM327 v2.2"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS1": ["OK"],
            "ATH1": ["OK"], "ATCAF0": ["OK"], "ATSP6": ["OK"],
            "ATCM 7FF": ["OK"], "ATCM 000": ["OK"],
            "ATCF 202": ["OK"], "ATCF 086": ["OK"], "ATCF 078": ["OK"],
            "ATCF 4B0": ["OK"], "ATCF 7E8": ["OK"],
            "ATMA": ["202 1F 40 00 00 0A 00 19 12\r086 3E 80 00 00 00 00 00 00"],
            "02 01 05": ["7E8 03 41 05 5A 00 00 00 00"],
        ])
        let session = CanMonitorSession(transport: transport)
        var sawRpm = false, sawPedal = false, sawSteering = false, sawCoolant = false
        var iterations = 0
        for await reading in await session.stream(signals: CanSignalMap.mazdaND,
                                                  dwell: .milliseconds(80),
                                                  interludePids: [.coolantTemp],
                                                  interludeEvery: 0) {
            switch reading {
            case .can(let key, let value, _):
                if key == "canRpm", abs(value - 2000) < 0.01 { sawRpm = true }
                if key == "accelPedal", abs(value - 4) < 0.01 { sawPedal = true }
                if key == "steeringAngle", abs(value) < 0.01 { sawSteering = true }
            case .obd(let channel, let value, _):
                if channel == .coolantTemp, abs(value - 50) < 0.01 { sawCoolant = true }
            }
            iterations += 1
            if (sawRpm && sawPedal && sawSteering && sawCoolant) || iterations > 400 { break }
        }
        await session.shutdown()
        XCTAssertTrue(sawRpm, "rpm from 0x202 slot")
        XCTAssertTrue(sawPedal, "pedal from 0x202 slot")
        XCTAssertTrue(sawSteering, "steering from 0x086 slot")
        XCTAssertTrue(sawCoolant, "coolant from the slow-PID interlude")
    }

    func testDiscoverCollectsTruthAndFrames() async {
        let transport = ReplayTransport(responses: [
            "ATCM 000": ["OK"], "ATCM 7FF": ["OK"], "ATCF 7E8": ["OK"],
            "ATMA": ["420 5A 00 00 00 00 00 00\rBUFFER FULL"],
            "02 01 05": ["7E8 03 41 05 5A 00 00 00 00"],
            "02 01 0C": ["7E8 04 41 0C 1F 40 00 00"],
        ])
        let session = CanMonitorSession(transport: transport)
        let report = await session.discover(duration: .milliseconds(900),
                                            truthChannels: [.coolantTemp, .rpm])
        await session.shutdown()
        XCTAssertTrue(report.frames.contains { $0.id == 0x420 }, "broadcast 0x420 tallied")
        XCTAssertFalse(report.frames.contains { $0.id == 0x7E8 }, "diagnostic replies excluded")
        XCTAssertTrue(report.analysis.contains { $0.contains("coolantTemp") }, "truth series reported")
        XCTAssertFalse(report.rawLog.isEmpty)
    }

    // MARK: - Correlator

    func testCorrelatorFindsCoolantByte() {
        // 0x420 byte0 = coolant + 40 (the Skyactiv encoding); truth sweeps 20→90 °C.
        var frames: [CanFrame] = []
        var truth: [(t: TimeInterval, value: Double)] = []
        for i in 0..<30 {
            let t = Double(i)
            let coolant = 20.0 + Double(i) * 2.4
            frames.append(CanFrame(id: 0x420, data: [UInt8(coolant + 40), 0x12, UInt8(i % 3), 0, 0, 0, 0, 0], t: t))
            truth.append((t: t + 0.3, value: coolant))
        }
        let candidates = CanCorrelator.match(frames: frames, truth: ["coolantTemp": truth])
        guard let best = candidates.first(where: { $0.truthChannel == "coolantTemp" && $0.byteOffset == 0 && $0.width == 1 }) else {
            return XCTFail("no candidate for 0x420 byte 0: \(candidates.map(\.summary))")
        }
        XCTAssertGreaterThan(best.correlation, 0.99)
        XCTAssertEqual(best.scale, 1.0, accuracy: 0.05)
        XCTAssertEqual(best.offset, -40, accuracy: 3)
    }

    func testCorrelatorFindsU16RpmAndIgnoresConstants() {
        // 0x202 u16[0] = rpm·4; byte2 constant; truth rpm sweeps.
        var frames: [CanFrame] = []
        var truth: [(t: TimeInterval, value: Double)] = []
        for i in 0..<40 {
            let t = Double(i) * 0.5
            let rpm = 800.0 + Double(i) * 60
            let raw = UInt32(rpm * 4)
            frames.append(CanFrame(id: 0x202, data: [UInt8(raw >> 8), UInt8(raw & 0xFF), 0x77, 0, 0, 0, 0, 0], t: t))
            truth.append((t: t + 0.2, value: rpm))
        }
        let candidates = CanCorrelator.match(frames: frames, truth: ["rpm": truth])
        guard let best = candidates.first(where: { $0.byteOffset == 0 && $0.width == 2 }) else {
            return XCTFail("no u16 candidate: \(candidates.map(\.summary))")
        }
        XCTAssertEqual(best.scale, 0.25, accuracy: 0.01)
        XCTAssertFalse(candidates.contains { $0.byteOffset == 2 && $0.width == 1 }, "constant byte must not correlate")
    }

    func testCorrelatorExcludesDiagnosticIDs() {
        var frames: [CanFrame] = []
        var truth: [(t: TimeInterval, value: Double)] = []
        for i in 0..<20 {
            let t = Double(i)
            let coolant = 20.0 + Double(i) * 3
            frames.append(CanFrame(id: 0x7E8, data: [0x03, 0x41, 0x05, UInt8(coolant + 40)], t: t))
            truth.append((t: t, value: coolant))
        }
        XCTAssertTrue(CanCorrelator.match(frames: frames, truth: ["coolantTemp": truth]).isEmpty)
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
