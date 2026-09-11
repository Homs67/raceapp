import XCTest
@testable import RaceBoxKit
import BleKit

/// End-to-end tests over the simulated transport: the whole stack — framing,
/// reassembly, routing, command/ACK correlation — with no hardware.
final class RaceBoxSessionTests: XCTestCase {

    private func makeSession(model: RaceBoxModel = .micro,
                             chunkSize: Int? = nil) -> (RaceBoxSession, RaceBoxSimulatedTransport) {
        let transport = RaceBoxSimulatedTransport(model: model, rate: .hz25)
        transport.notificationChunkSize = chunkSize
        return (RaceBoxSession(transport: transport), transport)
    }

    func testLiveDataFlowsAfterStart() async throws {
        let (session, transport) = makeSession()
        await session.start()
        transport.start()
        defer { transport.stop() }

        var received: [RaceBoxDataMessage] = []
        for await message in await session.liveData {
            received.append(message)
            if received.count >= 5 { break }
        }
        await session.shutdown()

        XCTAssertEqual(received.count, 5)
        XCTAssertTrue(received.allSatisfy { $0.hasValidFix })
        XCTAssertEqual(received[0].satellites, 12)
        let stats = await session.stats
        XCTAssertEqual(stats.checksumFailures, 0)
        XCTAssertGreaterThanOrEqual(stats.dataMessages, 5)
    }

    /// Real devices fragment notifications at low MTU; 20-byte chunks split
    /// every 88-byte data packet across five notifications.
    func testLiveDataSurvivesFragmentedNotifications() async throws {
        let (session, transport) = makeSession(chunkSize: 20)
        await session.start()
        transport.start()
        defer { transport.stop() }

        var received = 0
        for await message in await session.liveData {
            XCTAssertEqual(message.satellites, 12)
            received += 1
            if received >= 4 { break }
        }
        await session.shutdown()

        let stats = await session.stats
        XCTAssertEqual(stats.checksumFailures, 0, "reassembly must not corrupt packets")
        XCTAssertEqual(stats.bytesDiscarded, 0)
    }

    func testEncoderDecoderRoundTripsThroughTheWire() async throws {
        let sample = RaceBoxSample(
            latitude: 36.584200, longitude: -121.753600, altitudeMeters: 42.5,
            speedMps: 31.2, headingDegrees: 275.5,
            gForce: RaceBoxVector3(x: -0.42, y: 0.87, z: 0.99),
            rotationRate: RaceBoxVector3(x: 1.5, y: -2.25, z: 33.75),
            satellites: 14, hasFix: true)

        var parser = RaceBoxPacketParser()
        let packet = RaceBoxEncoder.dataMessage(sample, model: .micro)
        let decodedPacket = try XCTUnwrap(parser.feed(packet.encoded()).first)
        let message = try XCTUnwrap(RaceBoxDataMessage(payload: decodedPacket.payload))

        XCTAssertEqual(message.latitude, sample.latitude, accuracy: 1e-7)
        XCTAssertEqual(message.longitude, sample.longitude, accuracy: 1e-7)
        XCTAssertEqual(message.mslAltitude, sample.altitudeMeters, accuracy: 0.001)
        XCTAssertEqual(message.speedMps, sample.speedMps, accuracy: 0.001)
        XCTAssertEqual(message.headingDegrees, sample.headingDegrees, accuracy: 0.001)
        XCTAssertEqual(message.gForce.x, sample.gForce.x, accuracy: 0.001)
        XCTAssertEqual(message.gForce.y, sample.gForce.y, accuracy: 0.001)
        XCTAssertEqual(message.gForce.z, sample.gForce.z, accuracy: 0.001)
        XCTAssertEqual(message.rotationRate.z, sample.rotationRate.z, accuracy: 0.01)
        XCTAssertEqual(message.satellites, 14)
        XCTAssertEqual(message.power(for: .micro), .inputVoltage(12.1))
    }

    func testRecordingStatusCommandRoundTrip() async throws {
        let (session, _) = makeSession(model: .micro)
        await session.start()
        defer { Task { await session.shutdown() } }

        let status = try await session.recordingStatus()
        XCTAssertEqual(status.storedMessages, 67_173)
        XCTAssertEqual(status.memorySizeMessages, 196_608)
        XCTAssertFalse(status.isRecording)
    }

    func testSetRecordingIsAckedAndReadBack() async throws {
        let (session, _) = makeSession(model: .micro)
        await session.start()
        defer { Task { await session.shutdown() } }

        try await session.setRecording(.standingStarts)
        let config = try await session.recordingConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(config.flags.contains(.stationaryFilter))

        let status = try await session.recordingStatus()
        XCTAssertTrue(status.isRecording)

        try await session.stopRecording()
        let stopped = try await session.recordingStatus()
        XCTAssertFalse(stopped.isRecording)
    }

    /// A plain Mini has no memory — the device NACKs and we must surface that
    /// rather than hanging or pretending it worked.
    func testRecordingOnPlainMiniIsRejected() async throws {
        let (session, _) = makeSession(model: .mini)
        await session.start()
        defer { Task { await session.shutdown() } }

        do {
            try await session.setRecording(.recommended)
            XCTFail("expected NACK")
        } catch let error as RaceBoxError {
            XCTAssertEqual(error, .rejected(messageClass: 0xFF, messageID: 0x25))
        }
    }

    func testCommandTimesOutRatherThanHanging() async throws {
        // A transport that never answers: the command must fail, not hang.
        final class SilentTransport: BleTransportStub {
            override func send(_ data: Data) async throws {}
        }
        let transport = SilentTransport()
        let session = RaceBoxSession(transport: transport)
        await session.start()
        defer { Task { await session.shutdown() } }

        do {
            _ = try await session.execute(RaceBoxCommand.recordingStatusRequest(), timeout: 0.3)
            XCTFail("expected timeout")
        } catch let error as RaceBoxError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testConcurrentCommandsDoNotClobberEachOther() async throws {
        // Actor reentrancy alone would let these interleave and swap replies —
        // the same failure mode that broke ELM327 diagnostics.
        let (session, _) = makeSession(model: .micro)
        await session.start()
        defer { Task { await session.shutdown() } }

        async let first = session.recordingStatus()
        async let second = session.recordingConfig()
        async let third = session.recordingStatus()

        let (statusA, config, statusB) = try await (first, second, third)
        XCTAssertEqual(statusA.memorySizeMessages, 196_608)
        XCTAssertEqual(statusB.memorySizeMessages, 196_608)
        XCTAssertEqual(config.dataRate, .hz25)
    }

    func testShutdownFinishesStreams() async throws {
        let (session, transport) = makeSession()
        await session.start()
        transport.start()

        let task = Task {
            var count = 0
            for await _ in await session.liveData { count += 1 }
            return count   // returns only once the stream finishes
        }
        try await Task.sleep(for: .milliseconds(150))
        await session.shutdown()
        transport.stop()

        let delivered = await task.value
        XCTAssertGreaterThan(delivered, 0, "data flowed before shutdown")
    }
}

/// Minimal transport stub for negative-path tests.
class BleTransportStub: BleTransport, @unchecked Sendable {
    private var continuation: AsyncStream<Data>.Continuation?
    lazy var stream: AsyncStream<Data> = AsyncStream { self.continuation = $0 }
    var incoming: AsyncStream<Data> { stream }
    func send(_ data: Data) async throws {}
    func emit(_ data: Data) { continuation?.yield(data) }
}
