import XCTest
@testable import SessionKit

final class LapDeltaTests: XCTestCase {

    private func circle(points: Int = 250, radius: Double = 159) -> [GeoPoint] {
        let lat0 = 34.87, lon0 = -118.26
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        return (0..<points).map { i in
            let a = Double(i) / Double(points) * 2 * .pi
            return GeoPoint(lat: lat0 + radius * sin(a) / mLat, lon: lon0 + radius * cos(a) / mLon)
        }
    }

    /// Drive `laps` complete laps of a schedule through TrackProgress + LapDelta
    /// exactly as SessionMetrics does, sampling every `dt` seconds. Returns the
    /// deltas observed during the final lap.
    private func deltas(paces: [Double], dt: TimeInterval = 1.0) -> [TimeInterval] {
        let line = circle()
        let schedule = PacedLapSchedule(centerline: line, paces: paces)
        var progress = TrackProgress(centerline: line)
        let delta = LapDelta(lapLength: progress.lapLength)

        var lapIndex = 0
        var lapStart = 0.0
        var best: TimeInterval?
        var finalLap: [TimeInterval] = []
        let total = schedule.lapTimes.reduce(0, +)
        var t = 0.0
        while t < total - 0.01 {
            let s = schedule.sample(atElapsed: t)
            if s.lap != lapIndex {
                let lapTime = schedule.lapTimes[lapIndex]
                let isBest = best.map { lapTime < $0 } ?? true
                if isBest { best = lapTime }
                delta.lapCompleted(lapTime: lapTime, isNewBest: isBest)
                lapIndex = s.lap
                lapStart = t
            }
            if let fix = progress.locate(lat: s.position.lat, lon: s.position.lon) {
                delta.add(s: fix.s, elapsed: t - lapStart)
                if lapIndex == paces.count - 1, let d = delta.delta { finalLap.append(d) }
            }
            t += dt
        }
        return finalLap
    }

    func testNilBeforeAnyReferenceLap() {
        let delta = LapDelta(lapLength: 1000)
        delta.add(s: 10, elapsed: 1)
        delta.add(s: 40, elapsed: 3)
        XCTAssertNil(delta.delta)
    }

    func testIdenticalLapsReadZero() {
        let ds = deltas(paces: [0.85, 0.85])
        XCTAssertGreaterThan(ds.count, 20)
        for d in ds { XCTAssertEqual(d, 0, accuracy: 0.6, "1 Hz sampling + 5 m bins keep identical laps within a fix interval") }
    }

    func testSlowerLapReadsPositiveAndGrows() {
        let ds = deltas(paces: [0.85, 0.80])
        XCTAssertGreaterThan(ds.count, 20)
        XCTAssertGreaterThan(ds.last ?? 0, ds[ds.count / 4], "deficit accumulates over the lap")
        XCTAssertGreaterThan(ds.last ?? 0, 1.0)
    }

    func testFasterLapReadsNegative() {
        let ds = deltas(paces: [0.85, 0.90])
        XCTAssertLessThan(ds.last ?? 0, -1.0)
    }

    func testSecondBestDoesNotReplaceReference() {
        // Lap 1 at 0.90 is best; lap 2 slower; lap 3 must still compare to lap 1.
        let ds = deltas(paces: [0.90, 0.80, 0.85])
        XCTAssertGreaterThan(ds.last ?? 0, 0.5, "0.85 is slower than the 0.90 reference")
    }

    func testGapFillingInterpolatesMissingBins() {
        var bins: [TimeInterval?] = [0, nil, nil, 30, nil, 50]
        LapDelta.fillGaps(&bins)
        XCTAssertEqual(bins[1] ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(bins[2] ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(bins[4] ?? -1, 40, accuracy: 1e-9)
    }

    func testResetClearsReference() {
        let ds = deltas(paces: [0.85, 0.80])
        XCTAssertFalse(ds.isEmpty)
        let delta = LapDelta(lapLength: 1000)
        delta.add(s: 0, elapsed: 0); delta.add(s: 999, elapsed: 60)
        delta.lapCompleted(lapTime: 60, isNewBest: true)
        delta.add(s: 0, elapsed: 0); delta.add(s: 500, elapsed: 31)
        XCTAssertNotNil(delta.delta)
        delta.reset()
        XCTAssertNil(delta.delta)
    }
}
