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

    func testMotionSourceHandoverIsRecorded() async throws {
        // A logger owns gps.* for a while, drops out, and the phone takes over.
        // The switch changes the sample rate under every consumer, so an export
        // has to say where each stretch came from.
        _ = try await recorder.start(at: 0)
        for i in 0..<40 {
            let t = Double(i) * 0.04
            await recorder.ingest(channel: .rbSatellites, value: 12, at: t)
            await recorder.ingest(channel: .gpsSpeed, value: 20, at: t)
        }
        // Logger silent; phone GPS continues well past the 3 s handover window.
        for i in 0..<10 {
            await recorder.ingest(channel: .gpsSpeed, value: 18, at: 10 + Double(i))
        }
        let manifest = try await recorder.stop(at: 25)

        let segments = try XCTUnwrap(manifest.motionSourceSegments)
        XCTAssertEqual(segments.map(\.source), [.raceBox, .phone])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        XCTAssertGreaterThan(segments[1].start, 3, "phone takes over only after the logger goes quiet")
        XCTAssertFalse(manifest.phoneOnly)
    }

    func testPhoneOnlySessionHasNoRaceBoxSegment() async throws {
        _ = try await recorder.start(at: 0)
        for i in 0..<10 { await recorder.ingest(channel: .gpsSpeed, value: 12, at: Double(i)) }
        let manifest = try await recorder.stop(at: 11)
        XCTAssertEqual(manifest.motionSourceSegments?.map(\.source), [.phone])
    }

    func testCanStreamSessionCountsAsAdapterAlive() async throws {
        // During CAN streaming no obd.* arrives — can.* must still mark the
        // session non-phone-only and feed the highlights RPM peak.
        _ = try await recorder.start(at: 0)
        for i in 0..<30 {
            let t = Double(i) * 0.1
            await recorder.ingest(channel: .canRpm, value: 4000 + Double(i) * 10, at: t)
            await recorder.ingest(channel: .canSteering, value: -12, at: t)
        }
        let manifest = try await recorder.stop(at: 4)
        XCTAssertFalse(manifest.phoneOnly)
        XCTAssertEqual(manifest.highlights?.maxRpm, 4290)
        XCTAssertTrue(manifest.channels.contains { $0.id == .canSteering })
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

    // MARK: - Pause / resume

    /// Two 30 s runs either side of a four-minute pause in the paddock is one
    /// session of 60 s, not one of 300.
    func testPausedTimeIsNotRecordedTime() async throws {
        _ = try await recorder.start(at: 100)
        for i in 0..<31 { await recorder.ingest(channel: .gpsSpeed, value: 15, at: 100 + Double(i)) }
        try await recorder.pause(at: 130)
        try await recorder.resume(at: 370)
        for i in 0..<31 { await recorder.ingest(channel: .gpsSpeed, value: 15, at: 370 + Double(i)) }

        let manifest = try await recorder.stop(at: 400)
        XCTAssertEqual(manifest.segments?.count, 2)
        XCTAssertEqual(manifest.recordedSeconds(), 60, accuracy: 0.001)
        XCTAssertEqual(manifest.highlights?.durationSeconds ?? 0, 60, accuracy: 0.001,
                       "the 240 s pause must not count as recorded time")
    }

    func testEverySegmentIsClosedWhenTheSessionStops() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 5)
        try await recorder.pause(at: 10)
        try await recorder.resume(at: 60)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 65)
        let manifest = try await recorder.stop(at: 70)

        XCTAssertEqual(manifest.segments?.count, 2)
        XCTAssertTrue(manifest.segments?.allSatisfy { $0.end != nil } ?? false,
                      "a finalized session leaves no segment open")
    }

    func testSamplesArrivingWhilePausedAreDropped() async throws {
        let id = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 1)
        try await recorder.pause(at: 2)

        let paused = await recorder.isPaused
        XCTAssertTrue(paused)
        for i in 0..<20 { await recorder.ingest(channel: .gpsSpeed, value: 10, at: 3 + Double(i)) }

        try await recorder.resume(at: 100)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 101)
        let manifest = try await recorder.stop(at: 102)

        XCTAssertEqual(manifest.channels.first { $0.id == .gpsSpeed }?.sampleCount, 2,
                       "only the samples either side of the pause were written")
        let samples = ChannelReader.samples(for: .gpsSpeed,
                                            inSessionDirectory: store.directory(for: id))
        XCTAssertEqual(samples.map(\.t), [1, 101])
    }

    /// The accumulator integrates distance between consecutive speed samples.
    /// Across a pause there is no "between", so nothing should be added.
    func testPauseAddsNoPhantomDistance() async throws {
        _ = try await recorder.start(at: 0)
        for i in 0..<11 { await recorder.ingest(channel: .gpsSpeed, value: 20, at: Double(i)) }
        try await recorder.pause(at: 10)
        try await recorder.resume(at: 600)
        for i in 0..<11 { await recorder.ingest(channel: .gpsSpeed, value: 20, at: 600 + Double(i)) }

        let manifest = try await recorder.stop(at: 611)
        XCTAssertEqual(manifest.highlights?.distanceMeters ?? 0, 400, accuracy: 1,
                       "20 m/s × 10 s, twice — the pause contributes nothing")
    }

    func testPauseDoesNotLeaveASensorGapAcrossIt() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 1)
        try await recorder.pause(at: 2)
        try await recorder.resume(at: 500)
        await recorder.ingest(channel: .gpsSpeed, value: 10, at: 501)
        let manifest = try await recorder.stop(at: 502)

        let spanning = (manifest.sensorGaps ?? []).filter { $0.duration > 100 }
        XCTAssertTrue(spanning.isEmpty,
                      "a pause is not a GPS dropout — got \(spanning)")
    }

    func testAutoStopStandsDownWhilePaused() async throws {
        _ = try await recorder.start(at: 0)
        await recorder.ingest(channel: ChannelId.obd(.rpm), value: 2000, at: 10)
        await recorder.ingest(channel: .gpsSpeed, value: 20, at: 10)
        await recorder.ingest(channel: .gpsSpeed, value: 0, at: 20)
        try await recorder.pause(at: 25)

        let whilePaused = await recorder.shouldAutoStop(now: 10_000)
        XCTAssertFalse(whilePaused, "pausing is a deliberate stop, not a forgotten one")

        try await recorder.resume(at: 10_001)
        let justResumed = await recorder.shouldAutoStop(now: 10_010)
        XCTAssertFalse(justResumed, "the forgotten-stop clocks restart on resume")
        _ = try await recorder.stop(at: 10_020)
    }

    func testStoppingWhilePausedFinalizesCleanly() async throws {
        _ = try await recorder.start(at: 0)
        for i in 0..<21 { await recorder.ingest(channel: .gpsSpeed, value: 10, at: Double(i)) }
        try await recorder.pause(at: 20)

        let manifest = try await recorder.stop(at: 900)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertEqual(manifest.segments?.count, 1)
        XCTAssertEqual(manifest.highlights?.durationSeconds ?? 0, 20, accuracy: 0.001,
                       "the 880 s between pause and stop is not recorded time")
    }

    /// Sessions recorded before pause existed carry no segments at all.
    func testManifestWithoutSegmentsFallsBackToItsFinalizedDuration() {
        var legacy = SessionManifest(startedAtUTC: Date(), startUptime: 0, status: .complete)
        legacy.segments = nil
        var highlights = SessionManifest.Highlights()
        highlights.durationSeconds = 212
        legacy.highlights = highlights

        XCTAssertEqual(legacy.recordedSeconds(), 212, accuracy: 0.001)
    }

    func testOpenSegmentIsMeasuredToNow() {
        var live = SessionManifest(startedAtUTC: Date(), startUptime: 100)
        live.segments = [.init(start: 100, end: 160), .init(start: 400)]

        XCTAssertEqual(live.recordedSeconds(asOf: 430), 90, accuracy: 0.001)
        XCTAssertEqual(live.recordedSeconds(), 60, accuracy: 0.001,
                       "without a clock, only closed segments count")
    }
}
