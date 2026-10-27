import XCTest
@testable import SessionKit

final class GearTrackerTests: XCTestCase {

    private let gearing = GearEstimator.Gearing.mx5nd2

    private func rpm(speedMps: Double, gear: Int) -> Double {
        let wheelRpm = speedMps * 60 / gearing.tireCircumferenceMeters
        return wheelRpm * gearing.ratios[gear - 1] * gearing.finalDrive
    }

    /// Feed a steady stretch at 10 Hz (fresh speed and rpm each tick) and
    /// return what the widget showed at the end.
    @discardableResult
    private func cruise(_ tracker: inout GearTracker, gear: Int, speed: Double,
                        from t0: Double, seconds: Double = 1, brake: Double? = nil) -> Int {
        var last = -1
        var t = t0
        while t < t0 + seconds {
            last = tracker.update(rpm: rpm(speedMps: speed, gear: gear), rpmAt: t,
                                  speedMps: speed, speedAt: t, brakePercent: brake, at: t)
            t += 0.1
        }
        return last
    }

    func testNoEngineDataShowsNeutralNotBlank() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: nil, speedMps: 10, at: 0), 0)
        XCTAssertEqual(tracker.update(rpm: 0, speedMps: 0, at: 1), 0)
    }

    func testIdlingAtAStopIsNeutral() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: 800, speedMps: 0, at: 0), 0)
        XCTAssertEqual(tracker.update(rpm: 1100, speedMps: 1.2, at: 1), 0, "creeping at idle is still N")
        XCTAssertEqual(tracker.update(rpm: 3000, speedMps: 0, at: 2), 0, "revving while stationary is N")
    }

    func testLaunchReadsFirstWhileTheClutchSlips() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: 1700, speedMps: 1.0, at: 0), 1, "crawling with revs up = launching")
        // Clutch still slipping at 3 m/s: engine well above 1st's ratio, steadily.
        var t = 0.1, g = -1
        while t < 1 {
            g = tracker.update(rpm: rpm(speedMps: 3, gear: 1) * 1.4, rpmAt: t, speedMps: 3, speedAt: t, at: t)
            t += 0.1
        }
        XCTAssertEqual(g, 1)
    }

    func testSteadyDrivingReadsEveryGear() {
        var tracker = GearTracker()
        let speeds: [Double] = [6, 15, 22, 30, 36, 42]
        for gear in 1...6 {
            XCTAssertEqual(cruise(&tracker, gear: gear, speed: speeds[gear - 1], from: Double(gear) * 10), gear)
        }
    }

    func testClutchInCoastDoesNotWalkUpTheGears() {
        // The Oct 27 drive: 3rd at 19 m/s, clutch in, revs fall 3400 → 800
        // over ~2 s while speed barely changes. The bare ratio swept 4-5-6.
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 3, speed: 19, from: 0), 3)
        var seen = Set<Int>()
        var t = 1.0
        var r = rpm(speedMps: 19, gear: 3)
        while r > 800 {
            seen.insert(tracker.update(rpm: r, rpmAt: t, speedMps: 18.5, speedAt: t, at: t))
            r -= 130; t += 0.1
        }
        XCTAssertFalse(seen.contains(4) || seen.contains(5) || seen.contains(6), "\(seen)")
        XCTAssertTrue(seen.contains(3), "the coupled gear is held through the coast")
    }

    func testRealUpshiftIsFollowedOnceTheClutchBites() {
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 2, speed: 14, from: 0), 2)
        // Shift: half a second of clutch in, revs dropping, then coupled in 3rd.
        var t = 1.0
        for i in 0..<5 {
            _ = tracker.update(rpm: 4500 - Double(i) * 300, rpmAt: t, speedMps: 14, speedAt: t, at: t)
            t += 0.1
        }
        XCTAssertEqual(cruise(&tracker, gear: 3, speed: 14.5, from: t), 3)
    }

    func testBrakingNeverMovesTheGearUp() {
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 2, speed: 15, from: 0), 2)
        // On the brakes with lagging speed the steady ratio can sit on 3rd's.
        XCTAssertEqual(cruise(&tracker, gear: 3, speed: 15, from: 1, brake: 30), 2)
        // Off the brakes, a coupled 3rd is a real upshift.
        XCTAssertEqual(cruise(&tracker, gear: 3, speed: 15, from: 2), 3)
    }

    func testSlowPhoneSpeedStillResolvesCruising() {
        // 1 Hz speed samples; RPM arrives in bursts. Pairs form only when an
        // RPM reading is within 0.4 s of the speed sample.
        var tracker = GearTracker()
        var g = -1
        for second in 0..<5 {
            let st = Double(second)
            for k in 0..<10 {
                let t = st + Double(k) * 0.1
                g = tracker.update(rpm: rpm(speedMps: 25, gear: 4), rpmAt: t - 0.05,
                                   speedMps: 25, speedAt: st, at: t)
            }
        }
        XCTAssertEqual(g, 4)
    }

    func testCoastingToAStopWithTheClutchInBecomesNeutral() {
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 2, speed: 12, from: 0), 2)
        // Clutch in, revs to idle, still rolling: held, then neutral.
        XCTAssertEqual(tracker.update(rpm: 900, rpmAt: 1.5, speedMps: 11, speedAt: 1.5, at: 1.5), 2)
        XCTAssertEqual(tracker.update(rpm: 800, rpmAt: 5, speedMps: 10, speedAt: 5, at: 5), 0)
        XCTAssertEqual(tracker.update(rpm: 780, speedMps: 0.5, at: 8), 0)
    }

    func testSustainedMismatchStaysOnLastGear() {
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 2, speed: 15, from: 0), 2)
        // Wheelspin: engine 25% above 2nd's ratio, longer than the hold.
        let spinning = rpm(speedMps: 16, gear: 2) * 1.25
        XCTAssertEqual(tracker.update(rpm: spinning, rpmAt: 2, speedMps: 16, speedAt: 2, at: 2), 2)
        XCTAssertEqual(tracker.update(rpm: spinning, rpmAt: 6, speedMps: 16, speedAt: 6, at: 6), 2, "no blank after the hold")
    }

    func testEngineOffResetsTheHold() {
        var tracker = GearTracker()
        XCTAssertEqual(cruise(&tracker, gear: 3, speed: 20, from: 0), 3)
        XCTAssertEqual(tracker.update(rpm: nil, speedMps: 20, at: 1.5), 0)
        XCTAssertEqual(tracker.update(rpm: 2000, rpmAt: 2, speedMps: 20, speedAt: 2, at: 2), 0,
                       "no held gear after a reset → N, not 3")
    }
}
