import XCTest
@testable import SessionKit

/// The logger reports gravity + linear acceleration summed, in its own mount
/// axes, at 25 Hz. These cover the split and the alignment on top of it.
final class LoggerFrameTrackerTests: XCTestCase {

    private struct Mount {
        let down: Vector3
        let forward: Vector3
        var right: Vector3 { forward.cross(down * -1).normalized }

        init(down: Vector3, roughForward: Vector3) {
            let d = down.normalized
            self.down = d
            self.forward = (roughForward - d * roughForward.dot(d)).normalized
        }

        /// What the logger actually reports: gravity plus the car's motion.
        /// Gravity reads +1 g along "up" in an accelerometer at rest.
        func reading(lat: Double, long: Double) -> Vector3 {
            down * -1 + forward * long + right * lat
        }
    }

    /// An OBD port is low and steeply raked, so nothing here is axis-aligned.
    private let mount = Mount(down: Vector3(0.22, -0.31, -0.92),
                              roughForward: Vector3(0.85, 0.3, 0.15))

    /// Park, then drive at 25 Hz with speed 18 + 6·sin(t·2π/8) m/s — an 8 s
    /// accel/brake cycle. Deliberately faster than the 5 s gravity filter:
    /// a slower cycle is indistinguishable from the car changing attitude and
    /// gets absorbed into the gravity estimate, as real sustained pulls
    /// partially do.
    private func calibrate(lateral: (Double) -> Double = { _ in 0 })
        -> (tracker: LoggerFrameTracker, t: TimeInterval) {
        var tracker = LoggerFrameTracker()
        var t = 1000.0
        for _ in 0..<100 {               // 4 s parked: split converges, frame levels
            tracker.ingest(accel: mount.reading(lat: 0, long: 0), at: t)
            t += 0.04
        }
        XCTAssertEqual(tracker.phase, .aligning, "levels while parked")
        let driveStart = t
        let omega = 2 * Double.pi / 8
        for step in 0..<(60 * 25) {
            let dt = Double(step) / 25
            let longG = 6 * omega * cos(omega * dt) / 9.81
            tracker.ingest(accel: mount.reading(lat: lateral(dt), long: longG), at: t)
            tracker.ingestSpeed(18 + 6 * sin(omega * dt), at: t)
            t += 0.04
        }
        _ = driveStart
        return (tracker, t)
    }

    func testResolvesCarFrameFromRawLoggerAccelerometer() {
        var (tracker, t) = calibrate()
        XCTAssertEqual(tracker.phase, .calibrated)

        let g = tracker.ingest(accel: mount.reading(lat: 0, long: 0.5), at: t)
        XCTAssertNotNil(g)
        XCTAssertEqual(g!.longG, 0.5, accuracy: 0.06, "braking/accel lands on the forward axis")
        XCTAssertEqual(g!.latG, 0, accuracy: 0.06, "and does not leak into cornering")

        t += 0.04
        let corner = tracker.ingest(accel: mount.reading(lat: 0.4, long: 0), at: t)!
        XCTAssertEqual(corner.latG, 0.4, accuracy: 0.06)
        XCTAssertEqual(corner.longG, 0, accuracy: 0.06)
    }

    /// The fit must not mistake sustained cornering for forward acceleration.
    func testCorneringDoesNotRotateTheForwardAxis() {
        var (tracker, t) = calibrate(lateral: { 0.35 * sin($0 / 2.5) })
        XCTAssertEqual(tracker.phase, .calibrated)
        let g = tracker.ingest(accel: mount.reading(lat: 0, long: 0.5), at: t)!
        XCTAssertEqual(g.longG, 0.5, accuracy: 0.08)
        XCTAssertEqual(g.latG, 0, accuracy: 0.08)
    }

    /// Scale near 1.0 is what separates a real alignment from a plausible
    /// wrong one — the phone's 0.63 on the first ND2 drive was 51° out.
    func testFitQualityReportsUnitScale() {
        let (tracker, _) = calibrate()
        let quality = tracker.fitQuality
        XCTAssertNotNil(quality)
        XCTAssertEqual(quality!.scale, 1.0, accuracy: 0.1)
        XCTAssertTrue(quality!.isTrustworthy)
    }

    /// The one that matters on track: a long corner must not fade. An
    /// ungated EMA reads 0.24 g six seconds into a steady 0.8 g corner.
    func testSustainedCorneringDoesNotDecay() {
        var (tracker, t) = calibrate()
        var readings: [Double] = []
        for _ in 0..<(12 * 25) {
            if let g = tracker.ingest(accel: mount.reading(lat: 0.8, long: 0), at: t) {
                readings.append(g.latG)
            }
            t += 0.04
        }
        XCTAssertEqual(readings.first!, 0.8, accuracy: 0.06, "corner entry")
        XCTAssertEqual(readings.last!, 0.8, accuracy: 0.06, "still 0.8 g twelve seconds later")
    }

    /// Likewise a long pull or a hard, sustained brake.
    func testSustainedBrakingDoesNotDecay() {
        var (tracker, t) = calibrate()
        var last = 0.0
        for _ in 0..<(8 * 25) {
            if let g = tracker.ingest(accel: mount.reading(lat: 0, long: -0.7), at: t) { last = g.longG }
            t += 0.04
        }
        XCTAssertEqual(last, -0.7, accuracy: 0.06)
    }

    /// A disconnect leaves a hole; the EMA must re-seed rather than smear the
    /// step in gravity across the next several seconds of output.
    func testGapReseedsGravityInsteadOfSmearing() {
        var tracker = LoggerFrameTracker()
        var t = 1000.0
        for _ in 0..<100 {
            tracker.ingest(accel: mount.reading(lat: 0, long: 0), at: t)
            t += 0.04
        }
        t += 30                          // logger dropped out
        XCTAssertNil(tracker.ingest(accel: mount.reading(lat: 0, long: 0), at: t),
                     "first sample after a gap re-seeds gravity")
    }
}
