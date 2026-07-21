import XCTest
@testable import SessionKit

final class VideoTimelineTests: XCTestCase {

    private let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(_ name: String, startOffset: TimeInterval, duration: TimeInterval) -> VideoAsset {
        VideoAsset(fileName: name, wallClockStart: sessionStart.addingTimeInterval(startOffset),
                   duration: duration)
    }

    /// The exact dashcam scenario: recorder runs 1:00–2:00 in five 12-min files,
    /// session is 1:15–1:45. Only the 1:15–1:45 portions must survive.
    func testDashcamCropAcrossFiveClips() {
        let session: TimeInterval = 30 * 60 // 1:15 → 1:45
        let clips = (0..<5).map { i in
            clip("clip\(i + 1).mp4", startOffset: Double(i) * 720 - 900, duration: 720)
        }
        let segments = VideoTimeline.segments(assets: clips, sessionStartUTC: sessionStart,
                                              sessionDuration: session, syncOffset: 0)

        XCTAssertEqual(segments.map(\.fileName), ["clip2.mp4", "clip3.mp4", "clip4.mp4"],
                       "clips 1 and 5 are fully outside the session")
        // clip2 spans session −3:00…+9:00 → contributes 0:00–9:00, starting 3:00 into the file
        XCTAssertEqual(segments[0].sessionStart, 0, accuracy: 0.01)
        XCTAssertEqual(segments[0].assetStart, 180, accuracy: 0.01)
        XCTAssertEqual(segments[0].duration, 540, accuracy: 0.01)
        // clip3 fully inside: 9:00–21:00
        XCTAssertEqual(segments[1].sessionStart, 540, accuracy: 0.01)
        XCTAssertEqual(segments[1].assetStart, 0, accuracy: 0.01)
        XCTAssertEqual(segments[1].duration, 720, accuracy: 0.01)
        // clip4 head: 21:00–30:00
        XCTAssertEqual(segments[2].sessionStart, 1260, accuracy: 0.01)
        XCTAssertEqual(segments[2].duration, 540, accuracy: 0.01)

        XCTAssertEqual(VideoTimeline.coverage(segments: segments, sessionDuration: session), 1.0, accuracy: 0.001)
        XCTAssertTrue(VideoTimeline.gaps(segments: segments, sessionDuration: session).isEmpty)
    }

    func testGapsReported() {
        let session: TimeInterval = 600
        let clips = [
            clip("a.mp4", startOffset: 60, duration: 120),  // 1:00–3:00
            clip("b.mp4", startOffset: 300, duration: 120), // 5:00–7:00
        ]
        let segments = VideoTimeline.segments(assets: clips, sessionStartUTC: sessionStart,
                                              sessionDuration: session, syncOffset: 0)
        let gaps = VideoTimeline.gaps(segments: segments, sessionDuration: session)
        XCTAssertEqual(gaps.count, 3) // head, middle, tail
        XCTAssertEqual(gaps[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(gaps[0].end, 60, accuracy: 0.01)
        XCTAssertEqual(gaps[1].start, 180, accuracy: 0.01)
        XCTAssertEqual(gaps[1].end, 300, accuracy: 0.01)
        XCTAssertEqual(gaps[2].end, 600, accuracy: 0.01)
        XCTAssertEqual(VideoTimeline.coverage(segments: segments, sessionDuration: session),
                       240.0 / 600.0, accuracy: 0.001)
    }

    func testSyncOffsetShiftsPlacement() {
        let session: TimeInterval = 100
        // Camera clock 30 s fast: clip stamped 30 s after its true moment.
        let clips = [clip("a.mp4", startOffset: 30, duration: 100)]
        let noOffset = VideoTimeline.segments(assets: clips, sessionStartUTC: sessionStart,
                                              sessionDuration: session, syncOffset: 0)
        XCTAssertEqual(noOffset[0].sessionStart, 30, accuracy: 0.01)
        let corrected = VideoTimeline.segments(assets: clips, sessionStartUTC: sessionStart,
                                               sessionDuration: session, syncOffset: -30)
        XCTAssertEqual(corrected[0].sessionStart, 0, accuracy: 0.01)
        XCTAssertEqual(corrected[0].duration, 100, accuracy: 0.01)
    }

    func testFullyOutsideClipsDropped() {
        let segments = VideoTimeline.segments(
            assets: [clip("before.mp4", startOffset: -500, duration: 400),
                     clip("after.mp4", startOffset: 700, duration: 400)],
            sessionStartUTC: sessionStart, sessionDuration: 600, syncOffset: 0)
        XCTAssertTrue(segments.isEmpty)
    }

    func testOverlappingClipsResolved() {
        // Second clip starts before the first ends — earlier clip yields.
        let segments = VideoTimeline.segments(
            assets: [clip("a.mp4", startOffset: 0, duration: 100),
                     clip("b.mp4", startOffset: 80, duration: 100)],
            sessionStartUTC: sessionStart, sessionDuration: 300, syncOffset: 0)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].duration, 80, accuracy: 0.01)
        XCTAssertEqual(segments[1].sessionStart, 80, accuracy: 0.01)
        XCTAssertEqual(segments[1].sessionEnd, 180, accuracy: 0.01)
    }

    // MARK: - End-stamp detection (real dashcam batch: metadata = start + duration)

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        c.timeZone = cal.timeZone
        return cal.date(from: c)!
    }

    func testFilenameDateParsesRealDashcamName() {
        // Import-renamed file keeps the original dashcam suffix
        let name = "CD8E0A88-3A101614-DE84-4DAE-8B01-A46A2F42361E-20260719214903_000651.mp4"
        XCTAssertEqual(VideoTimeline.filenameDate(name), utc(2026, 7, 19, 21, 49, 3))
        XCTAssertNil(VideoTimeline.filenameDate("IMG_1234.mp4"))
        XCTAssertNil(VideoTimeline.filenameDate("GX010042.MP4"))
    }

    func testEndStampedCameraCorrectedToFilenameStart() {
        // Real data: metadata 21:52:03 = filename 21:49:03 + 180s duration
        let result = VideoTimeline.inferredStart(
            embeddedDate: utc(2026, 7, 19, 21, 52, 3), duration: 180,
            fileName: "20260719214903_000651.mp4")
        XCTAssertEqual(result.start, utc(2026, 7, 19, 21, 49, 3))
        XCTAssertTrue(result.endStamped)
    }

    func testStartStampedCameraKeepsMetadata() {
        // Metadata matches the filename time → already start-stamped
        let meta = utc(2026, 7, 19, 21, 49, 4)
        let result = VideoTimeline.inferredStart(
            embeddedDate: meta, duration: 180, fileName: "20260719214903_000651.mp4")
        XCTAssertEqual(result.start, meta)
        XCTAssertFalse(result.endStamped)
    }

    func testNoMetadataFallsBackToFilename() {
        let result = VideoTimeline.inferredStart(
            embeddedDate: nil, duration: 180, fileName: "20260719214903_000651.mp4")
        XCTAssertEqual(result.start, utc(2026, 7, 19, 21, 49, 3))
    }

    func testUnrelatedFilenameKeepsMetadataUnchanged() {
        let meta = utc(2026, 7, 19, 12, 0, 0)
        let result = VideoTimeline.inferredStart(embeddedDate: meta, duration: 300, fileName: "IMG_5566.MOV")
        XCTAssertEqual(result.start, meta)
        XCTAssertFalse(result.endStamped)
    }

    func testChannelSampleCursor() {
        let cursor = ChannelSampleCursor(samples: [
            ChannelSample(t: 100, value: 1),
            ChannelSample(t: 101, value: 2),
            ChannelSample(t: 105, value: 3),
        ])
        XCTAssertEqual(cursor.value(at: 100.4), 1)
        XCTAssertEqual(cursor.value(at: 100.6), 2)
        XCTAssertEqual(cursor.value(at: 104.9), 3)
        XCTAssertNil(cursor.value(at: 120), "beyond tolerance")
        XCTAssertNil(ChannelSampleCursor(samples: []).value(at: 100))
    }
}
