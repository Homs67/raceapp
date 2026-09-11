import XCTest
@testable import RaceBoxKit

/// Golden vectors transcribed from the RaceBox BLE Protocol Documentation
/// (Revision 9). Every expected value below is the doc's own decoding, so these
/// tests lock our field offsets and scale factors to the official spec.
final class RaceBoxProtocolTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt8($0, radix: 16) }
    }

    // MARK: - Data message (doc §RaceBox Data Message, example packet)

    /// The doc's worked example: RaceBox Mini, 2022-01-10 08:51:08 UTC,
    /// 42.6719035 N / 23.2887238 E, 11 satellites, 89 % battery.
    private let exampleDataPacket = """
        B5 62 FF 01 50 00 A0 E7 0C 07 E6 07 01 0A 08 33
        08 37 19 00 00 00 2A AD 4D 0E 03 01 EA 0B C6 93
        E1 0D 3B 37 6F 19 61 8C 09 00 0F 01 09 00 9C 03
        00 00 2C 07 00 00 23 00 00 00 00 00 00 00 D0 00
        00 00 88 A9 DD 00 2C 01 00 59 FD FF 71 00 CE 03
        2F FF 56 00 FC FF 06 DB
        """

    func testDocExampleDataMessageDecodes() throws {
        var parser = RaceBoxPacketParser()
        let packets = parser.feed(Data(bytes(exampleDataPacket)))

        XCTAssertEqual(packets.count, 1, "one complete packet")
        XCTAssertEqual(parser.checksumFailures, 0, "doc's checksum must validate")
        XCTAssertEqual(parser.bytesDiscarded, 0)

        let packet = try XCTUnwrap(packets.first)
        XCTAssertEqual(packet.kind, .liveData)
        XCTAssertEqual(packet.payload.count, 80)

        let message = try XCTUnwrap(RaceBoxDataMessage(payload: packet.payload))

        // Timing
        XCTAssertEqual(message.iTOW, 118_286_240)
        XCTAssertEqual(message.year, 2022)
        XCTAssertEqual(message.month, 1)
        XCTAssertEqual(message.day, 10)
        XCTAssertEqual(message.hour, 8)
        XCTAssertEqual(message.minute, 51)
        XCTAssertEqual(message.second, 8)
        XCTAssertEqual(message.timeAccuracyNs, 25)
        XCTAssertEqual(message.nanoseconds, 239_971_626)
        XCTAssertTrue(message.dateValid)
        XCTAssertTrue(message.timeValid)
        XCTAssertTrue(message.timeFullyResolved)

        // Fix
        XCTAssertEqual(message.fixStatus, .threeD)
        XCTAssertTrue(message.hasValidFix)
        XCTAssertEqual(message.satellites, 11)
        XCTAssertEqual(message.pdop, 3.0, accuracy: 0.001)
        XCTAssertTrue(message.coordinatesValid)

        // Position — the doc prints these exact figures
        XCTAssertEqual(message.latitude, 42.6719035, accuracy: 1e-7)
        XCTAssertEqual(message.longitude, 23.2887238, accuracy: 1e-7)
        XCTAssertEqual(message.wgsAltitude, 625.761, accuracy: 0.001)
        XCTAssertEqual(message.mslAltitude, 590.095, accuracy: 0.001)
        XCTAssertEqual(message.horizontalAccuracy, 0.924, accuracy: 0.001)
        XCTAssertEqual(message.verticalAccuracy, 1.836, accuracy: 0.001)

        // Motion
        XCTAssertEqual(message.speedMps, 0.035, accuracy: 1e-6)       // 35 mm/s
        XCTAssertEqual(message.headingDegrees, 0, accuracy: 1e-6)
        XCTAssertEqual(message.speedAccuracyMps, 0.208, accuracy: 1e-6)
        XCTAssertEqual(message.headingAccuracyDegrees, 145.26856, accuracy: 1e-5)

        // Sensors
        XCTAssertEqual(message.gForce.x, -0.003, accuracy: 1e-6)
        XCTAssertEqual(message.gForce.y, 0.113, accuracy: 1e-6)
        XCTAssertEqual(message.gForce.z, 0.974, accuracy: 1e-6)
        XCTAssertEqual(message.rotationRate.x, -2.09, accuracy: 1e-6)
        XCTAssertEqual(message.rotationRate.y, 0.86, accuracy: 1e-6)
        XCTAssertEqual(message.rotationRate.z, -0.04, accuracy: 1e-6)

        // Power byte is model-dependent — same 0x59 means two different things
        XCTAssertEqual(message.power(for: .mini), .battery(percent: 89, charging: false))
        XCTAssertEqual(message.power(for: .micro), .inputVoltage(8.9))
    }

    func testDocExampleTimestampIsUtc() throws {
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes(exampleDataPacket))).first)
        let message = try XCTUnwrap(RaceBoxDataMessage(payload: packet.payload))
        let date = try XCTUnwrap(message.timestamp)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(parts.year, 2022)
        XCTAssertEqual(parts.month, 1)
        XCTAssertEqual(parts.day, 10)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 51)
        // 08:51:08 + 0.2399 s of nanosecond correction
        XCTAssertEqual(parts.second, 8)
    }

    func testMicroReportsInputVoltage() {
        // Doc: "value of 0x79 means 12.1V"
        var payload = [UInt8](repeating: 0, count: 80)
        payload[67] = 0x79
        let message = RaceBoxDataMessage(payload: payload)
        XCTAssertEqual(message?.power(for: .micro), .inputVoltage(12.1))
    }

    func testChargingBitSplitsFromBatteryPercent() {
        var payload = [UInt8](repeating: 0, count: 80)
        payload[67] = 0x80 | 67            // charging + 67 %
        let message = RaceBoxDataMessage(payload: payload)
        XCTAssertEqual(message?.power(for: .miniS), .battery(percent: 67, charging: true))
    }

    func testInvalidFixAndCoordinateFlags() {
        var payload = [UInt8](repeating: 0, count: 80)
        payload[20] = 3          // claims 3D
        payload[21] = 0          // but valid-fix bit clear
        payload[66] = 1          // coordinates invalid
        let message = RaceBoxDataMessage(payload: payload)
        XCTAssertEqual(message?.hasValidFix, false, "3D alone is not enough — bit 0 must be set")
        XCTAssertEqual(message?.coordinatesValid, false)
    }

    func testShortPayloadRejected() {
        XCTAssertNil(RaceBoxDataMessage(payload: [UInt8](repeating: 0, count: 79)))
    }

    // MARK: - Framing

    func testChecksumMatchesDocAlgorithm() {
        // Doc example: recording status request B5 62 FF 22 00 00 21 62
        let packet = RaceBoxCommand.recordingStatusRequest()
        XCTAssertEqual(Array(packet.encoded()), bytes("B5 62 FF 22 00 00 21 62"))
    }

    func testEncodeDecodeRoundTrip() {
        let original = RaceBoxPacket(messageClass: 0xFF, messageID: 0x25,
                                     payload: RaceBoxRecordingConfig.recommended.payload)
        var parser = RaceBoxPacketParser()
        let decoded = parser.feed(original.encoded())
        XCTAssertEqual(decoded, [original])
    }

    func testPacketSplitAcrossNotifications() {
        // The doc is explicit: a notification may carry a fragment. Feeding the
        // example one byte at a time must still yield exactly one packet.
        let all = Data(bytes(exampleDataPacket))
        var parser = RaceBoxPacketParser()
        var packets: [RaceBoxPacket] = []
        for byte in all {
            packets.append(contentsOf: parser.feed(Data([byte])))
        }
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(parser.checksumFailures, 0)
        XCTAssertEqual(parser.bytesDiscarded, 0)
    }

    func testMultiplePacketsInOneNotification() {
        // And the reverse: the device packs several records per notification.
        var blob = Data()
        for _ in 0..<3 { blob.append(Data(bytes(exampleDataPacket))) }
        blob.append(RaceBoxCommand.recordingStatusRequest().encoded())
        var parser = RaceBoxPacketParser()
        let packets = parser.feed(blob)
        XCTAssertEqual(packets.count, 4)
        XCTAssertEqual(packets.prefix(3).map(\.kind), [.liveData, .liveData, .liveData])
        XCTAssertEqual(packets.last?.kind, .recordingStatus)
    }

    func testLeadingGarbageIsResynced() {
        var blob = Data([0x00, 0xFF, 0x12, 0xB5, 0x00])   // noise, incl. a lone B5
        blob.append(Data(bytes(exampleDataPacket)))
        var parser = RaceBoxPacketParser()
        let packets = parser.feed(blob)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(parser.bytesDiscarded, 5)
        XCTAssertEqual(parser.checksumFailures, 0)
    }

    func testCorruptedPacketIsCountedAndRecoveredFrom() {
        var corrupted = bytes(exampleDataPacket)
        corrupted[30] ^= 0xFF                              // flip a payload byte
        var blob = Data(corrupted)
        blob.append(Data(bytes(exampleDataPacket)))        // a good one follows
        var parser = RaceBoxPacketParser()
        let packets = parser.feed(blob)
        XCTAssertEqual(parser.checksumFailures, 1)
        XCTAssertEqual(packets.count, 1, "the good packet still arrives")
    }

    func testImpossibleLengthDoesNotStallTheStream() {
        // A "header" with a 0xFFFF length must not swallow the real packet.
        var blob = Data([0xB5, 0x62, 0xFF, 0x01, 0xFF, 0xFF])
        blob.append(Data(bytes(exampleDataPacket)))
        var parser = RaceBoxPacketParser()
        XCTAssertEqual(parser.feed(blob).count, 1)
    }

    // MARK: - Commands (doc example packets)

    func testRecordingStatusReplyDecodes() throws {
        // Doc: not recording, 34 %, security enabled+locked, 67173 of 196608
        let raw = bytes("B5 62 FF 22 0C 00 00 22 01 00 65 06 01 00 00 00 03 00 BF 74")
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(raw)).first)
        XCTAssertEqual(parser.checksumFailures, 0)

        let status = try XCTUnwrap(RaceBoxRecordingStatus(payload: packet.payload))
        XCTAssertFalse(status.isRecording)
        XCTAssertEqual(status.memoryLevelPercent, 34)
        XCTAssertTrue(status.securityEnabled)
        XCTAssertFalse(status.memoryUnlocked)
        XCTAssertEqual(status.storedMessages, 67_173)
        XCTAssertEqual(status.memorySizeMessages, 196_608)

        // 129435 records left at 25 Hz ≈ 86 minutes
        let remaining = try XCTUnwrap(status.remainingSeconds(at: .hz25))
        XCTAssertEqual(remaining, 5177.4, accuracy: 1)
    }

    func testRecordingConfigEncodesToDocExample() {
        // Doc: enable, 25 Hz, all filters, 1389 mm/s for 30 s, no-fix 30 s,
        // auto-shutdown 300 s → B5 62 FF 25 0C 00 01 00 1F 00 6D 05 1E 00 1E 00 2C 01 2B 15
        let packet = RaceBoxCommand.setRecording(.recommended)
        XCTAssertEqual(Array(packet.encoded()),
                       bytes("B5 62 FF 25 0C 00 01 00 1F 00 6D 05 1E 00 1E 00 2C 01 2B 15"))
    }

    func testRecordingConfigRoundTrips() throws {
        let config = try XCTUnwrap(RaceBoxRecordingConfig(payload: RaceBoxRecordingConfig.recommended.payload))
        XCTAssertEqual(config, .recommended)
        XCTAssertTrue(config.flags.contains(.stationaryFilter))
        // Standing starts must NOT trim the launch away
        XCTAssertFalse(RaceBoxRecordingConfig.standingStarts.flags.contains(.stationaryFilter))
    }

    func testRecordingStateChangeUsesItsOwnLayout() throws {
        // Doc: state 1 (start), 25 Hz, flags 1F, 1389 mm/s, 10/10/10 s.
        // Note rate at offset 2 and flags at 3 — NOT the config layout.
        let raw = bytes("B5 62 FF 26 0C 00 01 00 00 1F 6D 05 0A 00 0A 00 0A 00 E1 F8")
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(raw)).first)
        XCTAssertEqual(packet.kind, .recordingState)

        let change = try XCTUnwrap(RaceBoxRecordingStateChange(payload: packet.payload))
        XCTAssertEqual(change.state, .running)
        XCTAssertEqual(change.dataRate, .hz25)
        XCTAssertEqual(change.flags.rawValue, 0x1F)
        XCTAssertEqual(change.stationaryThresholdMmps, 1389)
        XCTAssertEqual(change.stationaryIntervalSeconds, 10)
        XCTAssertEqual(change.noFixIntervalSeconds, 10)
        XCTAssertEqual(change.autoShutdownIntervalSeconds, 10)
    }

    func testDownloadCommandsMatchDoc() throws {
        XCTAssertEqual(Array(RaceBoxCommand.startDownload().encoded()), bytes("B5 62 FF 23 00 00 22 65"))
        XCTAssertEqual(Array(RaceBoxCommand.cancelDownload().encoded()), bytes("B5 62 FF 23 01 00 FF 22 89"))

        // Doc reply: 780 records to follow
        var parser = RaceBoxPacketParser()
        let reply = try XCTUnwrap(parser.feed(Data(bytes("B5 62 FF 23 04 00 0C 03 00 00 35 3E"))).first)
        XCTAssertEqual(RaceBoxCommand.downloadRecordCount(payload: reply.payload), 780)
    }

    func testEraseCommandsAndProgressMatchDoc() throws {
        XCTAssertEqual(Array(RaceBoxCommand.eraseMemory().encoded()), bytes("B5 62 FF 24 00 00 23 68"))
        XCTAssertEqual(Array(RaceBoxCommand.cancelErase().encoded()), bytes("B5 62 FF 24 01 00 FF 23 8D"))

        var parser = RaceBoxPacketParser()
        let progress = try XCTUnwrap(parser.feed(Data(bytes("B5 62 FF 24 01 00 3B 5F C9"))).first)
        XCTAssertEqual(RaceBoxCommand.eraseProgress(payload: progress.payload), 59)
    }

    func testUnlockMemoryMatchesDoc() {
        // Doc: security code 123456 (0x1E240)
        XCTAssertEqual(Array(RaceBoxCommand.unlockMemory(code: 123_456).encoded()),
                       bytes("B5 62 FF 30 04 00 40 E2 01 00 56 08"))
    }

    func testGnssConfigMatchesDoc() throws {
        // Doc: airborne <4 g (8), 3D speed on, 2 m minimum accuracy
        let config = RaceBoxGnssConfig(dynamicPlatformModel: 8, enable3DSpeed: true,
                                       minimumHorizontalAccuracyMeters: 2)
        XCTAssertEqual(Array(RaceBoxCommand.setGnssConfig(config).encoded()),
                       bytes("B5 62 FF 27 03 00 08 01 02 34 0E"))
        XCTAssertTrue(config.isValid)
        XCTAssertFalse(RaceBoxGnssConfig(dynamicPlatformModel: 9, enable3DSpeed: false,
                                         minimumHorizontalAccuracyMeters: 3).isValid,
                       "device NACKs a platform model above 8")
    }

    func testAckDecodesTargetCommand() throws {
        // Doc: ACK of the unlock command
        var parser = RaceBoxPacketParser()
        let packet = try XCTUnwrap(parser.feed(Data(bytes("B5 62 FF 02 02 00 FF 30 32 3A"))).first)
        let ack = try XCTUnwrap(RaceBoxAcknowledgement(packet: packet))
        XCTAssertTrue(ack.isPositive)
        XCTAssertEqual(ack.messageClass, 0xFF)
        XCTAssertEqual(ack.messageID, 0x30)
    }

    // MARK: - Device identification

    func testModelParsingPrefersMiniSOverMini() {
        XCTAssertEqual(RaceBoxModel.parse("RaceBox Mini S"), .miniS)
        XCTAssertEqual(RaceBoxModel.parse("RaceBox Mini"), .mini)
        XCTAssertEqual(RaceBoxModel.parse("RaceBox Micro"), .micro)
        // Advertised names carry the serial suffix
        XCTAssertEqual(RaceBoxModel.parse("RaceBox Mini S 1234567890"), .miniS)
        XCTAssertEqual(RaceBoxModel.parse("RaceBox Micro 0987654321"), .micro)
        XCTAssertNil(RaceBoxModel.parse("VEEPEAK"))
        XCTAssertNil(RaceBoxModel.parse(nil))
    }

    func testCapabilitiesGateOnModelAndFirmware() {
        let oldMicro = RaceBoxDeviceInfo(model: .micro, serialNumber: "1",
                                         firmware: RaceBoxFirmware("3.2"),
                                         hardwareRevision: nil, manufacturer: nil)
        XCTAssertTrue(oldMicro.supportsStandaloneRecording)
        XCTAssertFalse(oldMicro.supportsGnssConfig, "GNSS config needs firmware 3.3")

        let newMicro = RaceBoxDeviceInfo(model: .micro, serialNumber: "1",
                                         firmware: RaceBoxFirmware("3.3"),
                                         hardwareRevision: nil, manufacturer: nil)
        XCTAssertTrue(newMicro.supportsGnssConfig)
        XCTAssertTrue(newMicro.supports20HzRecording)

        let mini = RaceBoxDeviceInfo(model: .mini, serialNumber: "1",
                                     firmware: RaceBoxFirmware("2.6"),
                                     hardwareRevision: nil, manufacturer: nil)
        XCTAssertFalse(mini.supportsStandaloneRecording, "plain Mini has no memory")
    }

    func testModelPowerTraits() {
        XCTAssertTrue(RaceBoxModel.micro.reportsInputVoltage)
        XCTAssertFalse(RaceBoxModel.micro.hasInternalBattery, "Micro is bus-powered — 12 V only")
        XCTAssertTrue(RaceBoxModel.miniS.hasInternalBattery)
        XCTAssertFalse(RaceBoxModel.mini.supportsStandaloneRecording)
    }

    func testFirmwareOrdering() {
        XCTAssertTrue(RaceBoxFirmware("3.3")! > RaceBoxFirmware("3.2")!)
        XCTAssertTrue(RaceBoxFirmware("10.0")! > RaceBoxFirmware("9.9")!)
        XCTAssertEqual(RaceBoxFirmware("2")?.minor, 0)
        XCTAssertNil(RaceBoxFirmware("x.y"))
    }
}
