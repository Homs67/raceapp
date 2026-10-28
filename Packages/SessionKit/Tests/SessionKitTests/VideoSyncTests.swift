import XCTest
@testable import SessionKit

final class VideoSyncTests: XCTestCase {

    private let sessionStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(startOffset: TimeInterval, duration: TimeInterval, role: VideoAsset.Role = .imported) -> VideoAsset {
        VideoAsset(fileName: "c.mp4", wallClockStart: sessionStart.addingTimeInterval(startOffset),
                   duration: duration, role: role)
    }

    /// The user's example: a 1-minute clip that belongs to the last minute of a
    /// 3-minute session sits at 2:00–3:00, and the axis is the session.
    func testShortClipInsideSession() {
        let span = VideoSyncLayout.span(of: clip(startOffset: 120, duration: 60), sessionStartUTC: sessionStart, offset: 0)
        XCTAssertEqual(span, 120...180)
        XCTAssertEqual(VideoSyncLayout.axis(sessionDuration: 180, spans: [span]), 0...180)
    }

    /// A 5-minute clip around a 2:10 session: the axis grows to the clip.
    func testLongClipAroundSession() {
        let span = VideoSyncLayout.span(of: clip(startOffset: -70, duration: 300), sessionStartUTC: sessionStart, offset: 0)
        XCTAssertEqual(VideoSyncLayout.axis(sessionDuration: 130, spans: [span]), -70...230)
    }

    func testOffsetShiftsSpan() {
        let span = VideoSyncLayout.span(of: clip(startOffset: 120, duration: 60), sessionStartUTC: sessionStart, offset: -4)
        XCTAssertEqual(span, 116...176)
    }

    func testCropClampsToAxisAndMinimumLength() {
        let axis: ClosedRange<TimeInterval> = -70...230
        XCTAssertEqual(VideoSyncLayout.clampCrop(-100...300, axis: axis), -70...230)
        XCTAssertEqual(VideoSyncLayout.clampCrop(50...50.2, axis: axis, minLength: 1), 50...51)
    }

    func testReviewWindowIsCropInsideSession() {
        XCTAssertNil(VideoSync().reviewWindow(sessionDuration: 130))
        let sync = VideoSync(cropStart: -10, cropEnd: 100)
        XCTAssertEqual(sync.reviewWindow(sessionDuration: 130), 0...100)
        XCTAssertNil(VideoSync(cropStart: 140, cropEnd: 200).reviewWindow(sessionDuration: 130))
    }

    func testCameraDefaultsAndOverride() {
        XCTAssertEqual(clip(startOffset: 0, duration: 1, role: .imported).slot, .front)
        XCTAssertEqual(clip(startOffset: 0, duration: 1, role: .rear).slot, .front)
        XCTAssertEqual(clip(startOffset: 0, duration: 1, role: .front).slot, .rear)
        var c = clip(startOffset: 0, duration: 1)
        c.camera = .rear
        XCTAssertEqual(c.slot, .rear)
    }

    /// Manifests from before Video sync keep their single offset for both cameras.
    func testLegacyOffsetDecodes() throws {
        var m = SessionManifest(startedAtUTC: sessionStart, startUptime: 0)
        m.videoSyncOffset = 2.4
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: JSONEncoder().encode(m))
        XCTAssertNil(decoded.videoSync)
        XCTAssertEqual(decoded.effectiveVideoSync.frontOffset, 2.4)
        XCTAssertEqual(decoded.effectiveVideoSync.rearOffset, 2.4)
    }

    func testSegmentsRespectReviewWindow() {
        let segments = VideoTimeline.segments(assets: [clip(startOffset: -10, duration: 200)],
                                              sessionStartUTC: sessionStart, sessionDuration: 130,
                                              syncOffset: 0, window: 20...100)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].sessionStart, 20, accuracy: 0.001)
        XCTAssertEqual(segments[0].assetStart, 30, accuracy: 0.001)
        XCTAssertEqual(segments[0].duration, 80, accuracy: 0.001)
    }

    /// A clip stamped hours after the session (wrong clock) is moved to the
    /// session start; one that already overlaps is left alone.
    func testRescueOffsetForClipsFarFromSession() {
        XCTAssertEqual(VideoSyncLayout.rescueOffset(spans: [14_000...14_042], sessionDuration: 120), -14_000)
        XCTAssertNil(VideoSyncLayout.rescueOffset(spans: [-10...30], sessionDuration: 120))
        XCTAssertNil(VideoSyncLayout.rescueOffset(spans: [], sessionDuration: 120))
    }
}
