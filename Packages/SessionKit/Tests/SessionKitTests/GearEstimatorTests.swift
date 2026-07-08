import XCTest
@testable import SessionKit

final class GearEstimatorTests: XCTestCase {

    private let estimator = GearEstimator()

    /// RPM the engine would show for a given speed and gear on the ND2.
    private func rpm(speedMps: Double, gear: Int) -> Double {
        let gearing = GearEstimator.Gearing.mx5nd2
        let wheelRpm = speedMps * 60 / gearing.tireCircumferenceMeters
        return wheelRpm * gearing.ratios[gear - 1] * gearing.finalDrive
    }

    func testEveryGearRoundtrips() {
        // Plausible speed per gear (m/s): 2nd at 15, 3rd at 22, etc.
        let speeds: [Double] = [6, 15, 22, 30, 36, 42]
        for gear in 1...6 {
            let speed = speeds[gear - 1]
            XCTAssertEqual(estimator.gear(rpm: rpm(speedMps: speed, gear: gear), speedMps: speed), gear)
        }
    }

    func testClutchInReturnsNil() {
        // 3rd-gear speed but idle RPM — clutch in / coasting in neutral
        XCTAssertNil(estimator.gear(rpm: 850, speedMps: 22))
    }

    func testStationaryReturnsNil() {
        XCTAssertNil(estimator.gear(rpm: 850, speedMps: 0))
        XCTAssertNil(estimator.gear(rpm: 3000, speedMps: 1))
    }

    func testMidShiftRatioReturnsNil() {
        // Halfway between 3rd (5.83) and 4th (4.57) overall — no confident match
        let speed = 25.0
        let wheelRpm = speed * 60 / 1.888
        XCTAssertNil(estimator.gear(rpm: wheelRpm * 5.2, speedMps: speed))
    }
}
