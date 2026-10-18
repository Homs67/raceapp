import XCTest
@testable import SessionKit

final class XTalkProbe: XCTestCase {
    private struct Mount {
        let down: Vector3; let forward: Vector3
        var right: Vector3 { forward.cross(down * -1).normalized }
        init(down: Vector3, roughForward: Vector3) {
            let d = down.normalized; self.down = d
            self.forward = (roughForward - d * roughForward.dot(d)).normalized
        }
        func accel(lat: Double, long: Double) -> Vector3 { forward * long + right * lat }
    }
    /// Phone path (CoreMotion hands gravity over separately) with the SAME
    /// cornering profile, to see whether cross-talk is inherent to the fit.
    func testPhoneCalibratorCrossTalk() {
        let mount = Mount(down: Vector3(0.22, -0.31, -0.92), roughForward: Vector3(0.85, 0.3, 0.15))
        var cal = CarFrameCalibrator()
        for i in 0..<200 {
            let n = Vector3(0.001 * sin(Double(i)), 0.001 * cos(Double(i)), 0)
            cal.ingestMotion(gravity: mount.down + n, userAccel: n)
        }
        let omega = 2 * Double.pi / 8
        for step in 0..<(60 * 100) {
            let dt = Double(step) / 100
            let longG = 6 * omega * cos(omega * dt) / 9.81
            cal.ingestMotion(gravity: mount.down, userAccel: mount.accel(lat: 0.35 * sin(dt / 2.5), long: longG))
            if step % 100 == 0 { cal.ingestSpeed(18 + 6 * sin(omega * dt), at: 1000 + dt) }
        }
        let g = cal.carFrame(userAccel: mount.accel(lat: 0, long: 0.5))!
        print("PHONE-PATH cross-talk: longG=\(g.longG) latG=\(g.latG) scale=\(cal.fitQuality!.scale)")
    }
}
