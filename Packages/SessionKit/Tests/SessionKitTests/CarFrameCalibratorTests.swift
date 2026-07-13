import XCTest
@testable import SessionKit

final class CarFrameCalibratorTests: XCTestCase {

    /// A phone mounted at an arbitrary tilt: define the car's down/forward/right
    /// axes as unit vectors in *device* coordinates and synthesize samples.
    private struct Mount {
        let down: Vector3
        let forward: Vector3
        var right: Vector3 { forward.cross(down * -1).normalized }

        init(down: Vector3, roughForward: Vector3) {
            let d = down.normalized
            self.down = d
            // Orthogonalize forward against down
            self.forward = (roughForward - d * roughForward.dot(d)).normalized
        }

        /// Device-frame user acceleration for a given car-frame (lat, long) g.
        func accel(lat: Double, long: Double) -> Vector3 {
            forward * long + right * lat
        }
    }

    /// Runs the standard calibration sequence: park (level), then accelerate.
    private func calibrated(mount: Mount) -> CarFrameCalibrator {
        var calibrator = CarFrameCalibrator()
        // Phase 1: parked, ~2 s of gravity samples with tiny noise
        for i in 0..<200 {
            let noise = Vector3(0.001 * sin(Double(i)), 0.001 * cos(Double(i)), 0)
            calibrator.ingestMotion(gravity: mount.down + noise, userAccel: noise)
        }
        XCTAssertEqual(calibrator.phase, .aligning, "leveling should complete while parked")
        // Phase 2: clean speed-up, 0.3 g forward for ~1.5 s while GPS speed climbs
        for i in 0..<150 {
            let t = Double(i) * 0.01
            if i % 10 == 0 { // 10 Hz-ish speed feed, accelerating hard
                calibrator.ingestSpeed(3.0 * t + 1, at: TimeInterval(1000 + t))
            }
            calibrator.ingestMotion(gravity: mount.down, userAccel: mount.accel(lat: 0, long: 0.3))
        }
        return calibrator
    }

    func testCalibratesAndTransformsAtArbitraryMountAngle() {
        // Phone tilted back and rotated — nothing axis-aligned
        let mount = Mount(down: Vector3(0.3, -0.25, -0.92), roughForward: Vector3(0.8, 0.4, 0.1))
        let calibrator = calibrated(mount: mount)
        XCTAssertEqual(calibrator.phase, .calibrated)

        // Pure acceleration → longG positive, latG ~0
        let accel = calibrator.carFrame(userAccel: mount.accel(lat: 0, long: 0.5))
        XCTAssertEqual(accel?.longG ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(accel?.latG ?? 1, 0, accuracy: 0.02)

        // Braking → longG negative
        let braking = calibrator.carFrame(userAccel: mount.accel(lat: 0, long: -0.8))
        XCTAssertEqual(braking?.longG ?? 0, -0.8, accuracy: 0.02)

        // Right-hand corner (car accelerates leftward? convention: +lat = rightward accel)
        let corner = calibrator.carFrame(userAccel: mount.accel(lat: 0.9, long: 0))
        XCTAssertEqual(corner?.latG ?? 0, 0.9, accuracy: 0.02)
        XCTAssertEqual(corner?.longG ?? 1, 0, accuracy: 0.02)

        // Combined trail-braking sample survives rotation intact
        let combined = calibrator.carFrame(userAccel: mount.accel(lat: 0.6, long: -0.4))
        XCTAssertEqual(combined?.latG ?? 0, 0.6, accuracy: 0.02)
        XCTAssertEqual(combined?.longG ?? 0, -0.4, accuracy: 0.02)
    }

    func testNoTransformBeforeCalibration() {
        var calibrator = CarFrameCalibrator()
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0.5, 0, 0)))
        // Leveling only — still no transform
        for _ in 0..<200 {
            calibrator.ingestMotion(gravity: Vector3(0, 0, -1), userAccel: .zero)
        }
        XCTAssertEqual(calibrator.phase, .aligning)
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0.5, 0, 0)))
    }

    func testLevelingIgnoresMovingSamples() {
        var calibrator = CarFrameCalibrator()
        // Bumpy driving: high userAccel — must NOT level off these
        for _ in 0..<500 {
            calibrator.ingestMotion(gravity: Vector3(0.5, 0.5, -0.7), userAccel: Vector3(0.3, 0.2, 0.1))
        }
        XCTAssertEqual(calibrator.phase, .leveling, "quasi-static gate must hold")
    }

    func testAlignmentRequiresSpeedIncrease() {
        var calibrator = CarFrameCalibrator()
        let mount = Mount(down: Vector3(0, 0, -1), roughForward: Vector3(0, 1, 0))
        for _ in 0..<200 {
            calibrator.ingestMotion(gravity: mount.down, userAccel: .zero)
        }
        // Strong horizontal accel but speed steady (e.g. braking bumps, cornering)
        calibrator.ingestSpeed(20, at: 1000)
        calibrator.ingestSpeed(20, at: 1001)
        for _ in 0..<300 {
            calibrator.ingestMotion(gravity: mount.down, userAccel: mount.accel(lat: 0.5, long: 0))
        }
        XCTAssertEqual(calibrator.phase, .aligning, "must not align without a speed-up")
    }

    func testResetStartsOver() {
        let mount = Mount(down: Vector3(0, 0, -1), roughForward: Vector3(0, 1, 0))
        var calibrator = calibrated(mount: mount)
        XCTAssertEqual(calibrator.phase, .calibrated)
        calibrator.reset()
        XCTAssertEqual(calibrator.phase, .leveling)
        XCTAssertNil(calibrator.carFrame(userAccel: Vector3(0, 0.3, 0)))
    }
}
