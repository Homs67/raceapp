import XCTest
@testable import SessionKit
import ObdKit

final class SessionRecorderTests: XCTestCase {

    private var store: SessionStore!
    private var recorder: SessionRecorder!

    override func setUp() {
        store = SessionStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-tests-\(UUID().uuidString)"))
        recorder = SessionRecorder(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }

    func testFullSessionLifecycle() async throws {
        let id = try await recorder.start(at: 100, utc: Date(timeIntervalSince1970: 1_800_000_000),
                                          car: .init(make: "Mazda", model: "MX-5"), units: "imperial")
        let recording = await recorder.isRecording
        XCTAssertTrue(recording)

        // 60 s drive: 1Hz GPS at 15 m/s, RPM sweep, some lateral G
        for i in 0..<60 {
            let t = 100.0 + Double(i)
            await recorder.ingest(channel: .gpsSpeed, value: 15, at: t)
            await recorder.ingest(channel: ChannelId.obd(.rpm), value: 3000 + Double(i) * 20, at: t)
            await recorder.ingest(channel: .imuAccelX, value: i == 30 ? 0.95 : 0.3, at: t)
            await recorder.ingest(channel: ChannelId.obd(.coolantTemp), value: 88 + Double(i % 3), at: t)
        }

        let manifest = try await recorder.stop(at: 160)
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertFalse(manifest.phoneOnly, "OBD samples arrived")
        XCTAssertEqual(manifest.highlights?.durationSeconds ?? 0, 59, accuracy: 0.001)
        XCTAssertEqual(manifest.highlights?.distanceMeters ?? 0, 885, accuracy: 1) // 15 m/s × 59 s
        XCTAssertEqual(manifest.highlights?.maxRpm, 3000 + 59 * 20)
        XCTAssertEqual(manifest.highlights?.peakLatG ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(manifest.highlights?.coolantMinC, 88)
        XCTAssertEqual(manifest.highlights?.coolantMaxC, 90)
        XCTAssertEqual(manifest.channels.first { $0.id == .gpsSpeed }?.sampleCount, 60)

        // Data really is on disk
        let samples = ChannelReader.samples(for: ChannelId.obd(.rpm),
                                            inSessionDirectory: store.directory(for: id))
        XCTAssertEqual(samples.count, 60)
    }

    func testPhoneOnlySession() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 1)
        let manifest = try await recorder.stop(at: 2)
        XCTAssertTrue(manifest.phoneOnly) // R1.4 — valid without OBD
    }

    func testBackgroundCheckpointFlushesWithoutEndingSession() async throws {
        let id = try await recorder.start(at: 100, flushInterval: 60)
        await recorder.ingest(channel: .gpsSpeed, value: 12.5, at: 101)

        await recorder.checkpoint()

        let recording = await recorder.isRecording
        XCTAssertTrue(recording)
        XCTAssertEqual(try store.manifest(for: id).status, .recording)
        XCTAssertEqual(
            ChannelReader.samples(for: .gpsSpeed,
                                  inSessionDirectory: store.directory(for: id)).count,
            1)
        _ = try await recorder.stop(at: 102)
    }

    func testObdGapMarking() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: ChannelId.obd(.rpm), value: 2000, at: 1)
        await recorder.obdLinkLost(at: 5)
        await recorder.ingest(channel: ChannelId.obd(.rpm), value: 2100, at: 12.5) // link back
        let manifest = try await recorder.stop(at: 20)
        XCTAssertEqual(manifest.obdGaps, [.init(start: 5, end: 12.5)])
    }

    func testPhoneSensorSuspensionGapIsRecorded() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 20, at: 1)
        await recorder.ingest(channel: .gpsSpeed, value: 20, at: 10)

        let manifest = try await recorder.stop(at: 10.1)

        XCTAssertEqual(manifest.sensorGaps, [
            .init(source: .gps, start: 1, end: 10),
        ])
    }

    func testGapStillOpenAtStopIsClosed() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: ChannelId.obd(.rpm), value: 2000, at: 1)
        await recorder.obdLinkLost(at: 5)
        let manifest = try await recorder.stop(at: 30)
        XCTAssertEqual(manifest.obdGaps, [.init(start: 5, end: 30)])
    }

    func testDoubleStartThrows() async throws {
        _ = try await recorder.start(at: 0)
        do {
            _ = try await recorder.start(at: 1)
            XCTFail("expected alreadyRecording")
        } catch {}
        _ = try await recorder.stop(at: 2)
    }

    func testAutoStopFiresAfterObdGoneAndStationary() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: ChannelId.obd(.rpm), value: 2000, at: 10) // driving
        await recorder.ingest(channel: .gpsSpeed, value: 20, at: 10)
        // Park: ignition off (no more OBD), stationary
        await recorder.ingest(channel: .gpsSpeed, value: 0, at: 20)

        let tooSoon = await recorder.shouldAutoStop(now: 200)
        XCTAssertFalse(tooSoon, "only ~3 min in")
        let fires = await recorder.shouldAutoStop(now: 10 + 301)
        XCTAssertTrue(fires, "OBD silent and stationary for >5 min")
        _ = try await recorder.stop(at: 320)
    }

    func testAutoStopNeverFiresPhoneOnly() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 0, at: 1) // parked from the start
        let fires = await recorder.shouldAutoStop(now: 10_000)
        XCTAssertFalse(fires, "no OBD ever seen — no ignition-off signal (R1.6 scope)")
        _ = try await recorder.stop(at: 10_001)
    }
}
