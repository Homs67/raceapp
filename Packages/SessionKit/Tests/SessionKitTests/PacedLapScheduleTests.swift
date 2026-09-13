import XCTest
@testable import SessionKit

final class PacedLapScheduleTests: XCTestCase {

    private func circle(points: Int = 250, radius: Double = 159) -> [GeoPoint] {
        let lat0 = 34.87, lon0 = -118.26
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        return (0..<points).map { i in
            let a = Double(i) / Double(points) * 2 * .pi
            return GeoPoint(lat: lat0 + radius * sin(a) / mLat, lon: lon0 + radius * cos(a) / mLon)
        }
    }

    func testLapIndexIncrementsAtCumulativeLapTimes() {
        let schedule = PacedLapSchedule(centerline: circle(), paces: [0.85, 0.80, 0.90])
        let t1 = schedule.lapTimes[0], t2 = t1 + schedule.lapTimes[1]
        XCTAssertEqual(schedule.sample(atElapsed: t1 - 0.5).lap, 0)
        XCTAssertEqual(schedule.sample(atElapsed: t1 + 0.5).lap, 1)
        XCTAssertEqual(schedule.sample(atElapsed: t2 + 0.5).lap, 2)
        let cycle = schedule.lapTimes.reduce(0, +)
        XCTAssertEqual(schedule.sample(atElapsed: cycle + 0.5).lap, 3, "keeps counting across cycles")
    }

    func testSlowerPaceTakesLonger() {
        let schedule = PacedLapSchedule(centerline: circle(), paces: [0.85, 0.80, 0.90])
        XCTAssertGreaterThan(schedule.lapTimes[1], schedule.lapTimes[0])
        XCTAssertLessThan(schedule.lapTimes[2], schedule.lapTimes[0])
    }

    func testPositionIsContinuousAcrossTheLapBoundary() {
        let schedule = PacedLapSchedule(centerline: circle(), paces: [0.85, 0.80])
        let t1 = schedule.lapTimes[0]
        let before = schedule.sample(atElapsed: t1 - 0.05).position
        let after = schedule.sample(atElapsed: t1 + 0.05).position
        let mLat = 110_540.0, mLon = 111_320.0 * cos(before.lat * .pi / 180)
        let d = hypot((after.lat - before.lat) * mLat, (after.lon - before.lon) * mLon)
        XCTAssertLessThan(d, 6, "within ~0.1 s of travel — no teleport at the line")
    }
}
