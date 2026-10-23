import XCTest
@testable import SessionKit

final class GearTrackerTests: XCTestCase {

    private let gearing = GearEstimator.Gearing.mx5nd2

    private func rpm(speedMps: Double, gear: Int) -> Double {
        let wheelRpm = speedMps * 60 / gearing.tireCircumferenceMeters
        return wheelRpm * gearing.ratios[gear - 1] * gearing.finalDrive
    }

    func testNoEngineDataShowsNothing() {
        var tracker = GearTracker()
        XCTAssertNil(tracker.update(rpm: nil, speedMps: 10, at: 0))
        XCTAssertNil(tracker.update(rpm: 0, speedMps: 0, at: 1))
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
        // 3 m/s with the engine well above 1st's ratio: clutch still slipping.
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 3, gear: 1) * 1.4, speedMps: 3, at: 0.5), 1)
    }

    func testCleanRatioMatchesEveryGear() {
        var tracker = GearTracker()
        let speeds: [Double] = [6, 15, 22, 30, 36, 42]
        for gear in 1...6 {
            XCTAssertEqual(tracker.update(rpm: rpm(speedMps: speeds[gear - 1], gear: gear),
                                          speedMps: speeds[gear - 1], at: Double(gear)), gear)
        }
    }

    func testShiftHoldsThePreviousGearThenResolves() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 20, gear: 3), speedMps: 20, at: 0), 3)
        // Mid-shift: ratio halfway between 3rd and 4th for 0.8 s.
        let midway = (gearing.ratios[2] + gearing.ratios[3]) / 2 * gearing.finalDrive
        let wheelRpm = 21 * 60 / gearing.tireCircumferenceMeters
        XCTAssertEqual(tracker.update(rpm: midway * wheelRpm, speedMps: 21, at: 0.4), 3, "held")
        XCTAssertEqual(tracker.update(rpm: midway * wheelRpm, speedMps: 21, at: 0.8), 3, "still held")
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 22, gear: 4), speedMps: 22, at: 1.1), 4)
    }

    func testCoastingToAStopWithTheClutchInBecomesNeutral() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 12, gear: 2), speedMps: 12, at: 0), 2)
        // Clutch in, revs fall to idle, car still rolling at 10 m/s.
        XCTAssertEqual(tracker.update(rpm: 900, speedMps: 11, at: 1), 2, "within the hold window")
        XCTAssertEqual(tracker.update(rpm: 800, speedMps: 10, at: 3), 0, "hold expired at idle → N")
        XCTAssertEqual(tracker.update(rpm: 780, speedMps: 0.5, at: 8), 0)
    }

    func testSustainedMismatchStaysOnLastGear() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 15, gear: 2), speedMps: 15, at: 0), 2)
        // Wheelspin: engine 25% above 2nd's ratio for longer than the hold.
        let spinning = rpm(speedMps: 16, gear: 2) * 1.25
        XCTAssertEqual(tracker.update(rpm: spinning, speedMps: 16, at: 1), 2)
        XCTAssertEqual(tracker.update(rpm: spinning, speedMps: 16, at: 3), 2, "no blank after the hold")
    }

    func testReversingOutOfASpaceReadsR() {
        var tracker = GearTracker()
        // Sitting at idle, then speed climbs to 1.5 m/s over a second while
        // the car-frame G points backwards: reversing.
        XCTAssertEqual(tracker.update(rpm: 800, speedMps: 0, longG: 0, at: 0), 0)
        var last: Int? = nil
        for i in 0...25 {
            let t = 1 + Double(i) * 0.04
            last = tracker.update(rpm: 1100, speedMps: 0.4 + Double(i) * 0.05, longG: -0.1, at: t)
        }
        XCTAssertEqual(last, -1)
        // Braking while reversing: speed falls, G points forward. Still R.
        for i in 0...25 {
            let t = 2.1 + Double(i) * 0.04
            last = tracker.update(rpm: 900, speedMps: 1.6 - Double(i) * 0.05, longG: 0.1, at: t)
        }
        XCTAssertEqual(last, -1)
        // Stop for 2 s, then launch forward: back to 1st.
        for i in 0...50 { _ = tracker.update(rpm: 800, speedMps: 0, longG: 0, at: 3.2 + Double(i) * 0.04) }
        XCTAssertEqual(tracker.update(rpm: 800, speedMps: 0, longG: 0, at: 5.3), 0)
        for i in 0...25 {
            last = tracker.update(rpm: 1800, speedMps: 0.4 + Double(i) * 0.06, longG: 0.15, at: 5.4 + Double(i) * 0.04)
        }
        XCTAssertEqual(last, 1)
    }

    func testForwardLaunchNeverReadsR() {
        var tracker = GearTracker()
        var seen = Set<Int?>()
        for i in 0...50 {
            seen.insert(tracker.update(rpm: 1500 + Double(i) * 40, speedMps: Double(i) * 0.1,
                                       longG: 0.2, at: Double(i) * 0.04))
        }
        XCTAssertFalse(seen.contains(-1))
    }

    func testNoCarFrameGMeansNoReverse() {
        var tracker = GearTracker()
        var last: Int? = nil
        for i in 0...25 {
            last = tracker.update(rpm: 1100, speedMps: 0.4 + Double(i) * 0.05, longG: nil, at: Double(i) * 0.04)
        }
        XCTAssertNotEqual(last, -1)
    }

    func testEngineOffResetsTheHold() {
        var tracker = GearTracker()
        XCTAssertEqual(tracker.update(rpm: rpm(speedMps: 20, gear: 3), speedMps: 20, at: 0), 3)
        XCTAssertNil(tracker.update(rpm: nil, speedMps: 20, at: 0.5))
        XCTAssertEqual(tracker.update(rpm: 2000, speedMps: 20, at: 1), nil, "no held gear after a reset")
    }
}
