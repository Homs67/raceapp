import XCTest
@testable import SessionKit

final class CarFrameCalibratorTests: XCTestCase {

    /// A sensor held at an arbitrary angle: define the car's down/forward/right
    /// axes as unit vectors in *sensor* coordinates and synthesize samples.
    private struct Mount {
        let down: Vector3
        let forward: Vector3
        var right: Vector3 { forward.cross(down * -1).normalized }

        init(down: Vector3, roughForward: Vector3) {
            let d = down.normalized
            self.down = d
            self.forward = (roughForward - d * roughForward.dot(d)).normalized
        }

        /// Sensor-frame user acceleration for a given car-frame (lat, long) g.
        func accel(lat: Double, long: Double) -> Vector3 {
            forward * long + right * lat
        }
    }

    private let tiltedMount = Mount(down: Vector3(0.3, -0.25, -0.92),
                                    roughForward: Vector3(0.8, 0.4, 0.1))

    /// Park until leveled.
    private func level(_ calibrator: inout CarFrameCalibrator, mount: Mount,
                       gyro: Vector3? = nil) {
        for i in 0..<200 {
            let noise = Vector3(0.001 * sin(Double(i)), 0.001 * cos(Double(i)), 0)
            calibrator.ingestMotion(gravity: mount.down + noise, userAccel: noise,
                                    rotationRate: gyro)
        }
    }

    /// Drive for `seconds` with speed 15 + 8·sin(t/6) m/s — always well above
    /// walking pace, with continuous acceleration and braking to fit against.
    /// `lateral` adds a cornering component the fit must not mistake for
    /// forward. Motion at 100 Hz, speed at 1 Hz like real phone GPS.
    private func drive(_ calibrator: inout CarFrameCalibrator, mount: Mount,
                       seconds: Int, startT: TimeInterval = 1000,
                       lateral: (Double) -> Double = { _ in 0 }) {
        for step in 0..<(seconds * 100) {
            let t = Double(step) / 100
            let longG = (8.0 / 6.0) * cos(t / 6) / 9.81
            calibrator.ingestMotion(gravity: mount.down,
                                    userAccel: mount.accel(lat: lateral(t), long: longG))
            if step % 100 == 0 {
                calibrator.ingestSpeed(15 + 8 * sin(t / 6), at: startT + t)
            }
        }
    }

    private func calibrated(mount: Mount, seconds: Int = 40) -> CarFrameCalibrator {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: mount)
        XCTAssertEqual(calibrator.phase, .aligning, "leveling completes while parked")
        drive(&calibrator, mount: mount, seconds: seconds)
        return calibrator
    }

    // MARK: - Core transform

    func testCalibratesAndTransformsAtArbitraryMountAngle() {
        let calibrator = calibrated(mount: tiltedMount)
        XCTAssertEqual(calibrator.phase, .calibrated)

        let accel = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0, long: 0.5))
        XCTAssertEqual(accel?.longG ?? 0, 0.5, accuracy: 0.03)
        XCTAssertEqual(accel?.latG ?? 1, 0, accuracy: 0.03)

        let braking = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0, long: -0.8))
        XCTAssertEqual(braking?.longG ?? 0, -0.8, accuracy: 0.03)

        let corner = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0.9, long: 0))
        XCTAssertEqual(corner?.latG ?? 0, 0.9, accuracy: 0.03)
        XCTAssertEqual(corner?.longG ?? 1, 0, accuracy: 0.03)

        let combined = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0.6, long: -0.4))
        XCTAssertEqual(combined?.latG ?? 0, 0.6, accuracy: 0.03)
        XCTAssertEqual(combined?.longG ?? 0, -0.4, accuracy: 0.03)
    }

    /// The fitted projection length is the health signal the session validator
    /// keys on: ~1.0 means the axis absorbs all of the measured acceleration.
    func testFitReportsUnitScale() throws {
        let calibrator = calibrated(mount: tiltedMount)
        let quality = try XCTUnwrap(calibrator.fitQuality)
        XCTAssertEqual(quality.scale, 1.0, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(quality.windowCount, 20)
        XCTAssertTrue(quality.isTrustworthy)
    }

    // MARK: - The failure this replaced

    /// Regression for the 2026-09-11 session. The old calibrator locked its
    /// forward axis onto ONE acceleration event; that event happened while the
    /// car was still turning, so forward ended up ~58° off for the whole drive.
    /// A fit across many windows must not be captured by an early dirty event.
    func testEarlyCorneringDoesNotCaptureTheForwardAxis() {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: tiltedMount)
        // First 8 s: accelerating hard while also cornering hard — exactly the
        // "pulling out of a junction" case that poisoned the one-shot lock.
        drive(&calibrator, mount: tiltedMount, seconds: 8, startT: 1000) { _ in 0.6 }
        // Then ordinary straight-ish driving.
        drive(&calibrator, mount: tiltedMount, seconds: 40, startT: 1010) { t in 0.05 * sin(t / 3) }

        XCTAssertEqual(calibrator.phase, .calibrated)
        let accel = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0, long: 0.5))
        // The old behaviour scored ~0.26 here (cos 58°). Anything above ~0.47
        // would already beat it; require the axis to be genuinely recovered.
        XCTAssertEqual(accel?.longG ?? 0, 0.5, accuracy: 0.08,
                       "forward must survive a dirty early event")
        XCTAssertEqual(accel?.latG ?? 1, 0, accuracy: 0.08)
    }

    /// GPS speed is unsigned, so reversing reads as "speeding up" and would
    /// teach the fit a backwards forward axis. Low-speed manoeuvring is excluded.
    func testReversingDoesNotFlipTheForwardAxis() {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: tiltedMount)

        // Back out of a driveway: speed rises 0 → 2.5 m/s while the car
        // accelerates *backwards*.
        for step in 0..<600 {
            let t = Double(step) / 100
            calibrator.ingestMotion(gravity: tiltedMount.down,
                                    userAccel: tiltedMount.accel(lat: 0, long: -0.25))
            if step % 100 == 0 { calibrator.ingestSpeed(0.4 * t, at: 900 + t) }
        }
        // Then drive forward normally.
        drive(&calibrator, mount: tiltedMount, seconds: 40)

        XCTAssertEqual(calibrator.phase, .calibrated)
        let accel = calibrator.carFrame(userAccel: tiltedMount.accel(lat: 0, long: 0.5))
        XCTAssertGreaterThan(accel?.longG ?? -1, 0.4,
                             "accelerating forward must read positive, not inverted")
    }

    // MARK: - Gyro bias

    func testGyroBiasMeasuredWhileStationary() throws {
        var calibrator = CarFrameCalibrator()
        // A real Micro showed a steady +1.22 °/s on pitch while sitting still.
        let bias = Vector3(-0.18, 1.22, -0.80)
        level(&calibrator, mount: tiltedMount, gyro: bias)

        let measured = try XCTUnwrap(calibrator.gyroBias)
        XCTAssertEqual(measured.y, 1.22, accuracy: 0.01)
        XCTAssertEqual(measured.x, -0.18, accuracy: 0.01)

        // Corrected output removes the offset but keeps real rotation.
        let corrected = calibrator.correctedRotation(Vector3(-0.18, 1.22, 24.2))
        XCTAssertEqual(corrected.y, 0, accuracy: 0.01)
        XCTAssertEqual(corrected.z, 25.0, accuracy: 0.01)
    }

    func testNoGyroBiasWhenNotSupplied() {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: tiltedMount)
        XCTAssertEqual(calibrator.gyroBias, .zero, "no samples averages to zero")
        let rate = Vector3(1, 2, 3)
        XCTAssertEqual(calibrator.correctedRotation(rate), rate)
    }

    // MARK: - Guards

    func testNoTransformBeforeCalibration() {
        var calibrator = CarFrameCalibrator()
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0.5, 0, 0)))
        level(&calibrator, mount: tiltedMount)
        XCTAssertEqual(calibrator.phase, .aligning)
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0.5, 0, 0)))
    }

    func testLevelingIgnoresMovingSamples() {
        var calibrator = CarFrameCalibrator()
        for _ in 0..<500 {
            calibrator.ingestMotion(gravity: Vector3(0.5, 0.5, -0.7),
                                    userAccel: Vector3(0.3, 0.2, 0.1))
        }
        XCTAssertEqual(calibrator.phase, .leveling, "quasi-static gate must hold")
    }

    /// Cruising at a steady speed gives the fit nothing to work with, however
    /// long it lasts — it must stay honest rather than solve a singular system.
    func testConstantSpeedNeverAligns() {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: tiltedMount)
        for step in 0..<6000 {
            let t = Double(step) / 100
            calibrator.ingestMotion(gravity: tiltedMount.down,
                                    userAccel: tiltedMount.accel(lat: 0.2, long: 0))
            if step % 100 == 0 { calibrator.ingestSpeed(20, at: 1000 + t) }
        }
        XCTAssertEqual(calibrator.phase, .aligning)
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0, 0.3, 0)))
    }

    /// A long stall (locked screen, lost fix) must not be treated as one huge
    /// window, which would invent an acceleration that never happened.
    func testGapDoesNotProduceAFalseWindow() {
        var calibrator = CarFrameCalibrator()
        level(&calibrator, mount: tiltedMount)
        calibrator.ingestSpeed(5, at: 1000)
        for _ in 0..<500 {
            calibrator.ingestMotion(gravity: tiltedMount.down, userAccel: .zero)
        }
        calibrator.ingestSpeed(30, at: 1060)   // 60 s later — not a 4 g launch
        XCTAssertEqual(calibrator.phase, .aligning)
    }

    func testResetStartsOver() {
        var calibrator = calibrated(mount: tiltedMount)
        XCTAssertEqual(calibrator.phase, .calibrated)
        calibrator.reset()
        XCTAssertEqual(calibrator.phase, .leveling)
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0, 0.3, 0)))
        XCTAssertNil(calibrator.fitQuality)
    }

    func testSolverRejectsSingularSystem() {
        XCTAssertNil(CarFrameCalibrator.solve3x3(
            [[0, 0, 0], [0, 0, 0], [0, 0, 0]], [1, 1, 1]))
    }
}
