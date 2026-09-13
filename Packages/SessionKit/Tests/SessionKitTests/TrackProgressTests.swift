import XCTest
@testable import SessionKit

final class TrackProgressTests: XCTestCase {

    /// A 1 km circle of 250 points, driven by the simulator.
    private func circle(points: Int = 250, radius: Double = 159) -> [GeoPoint] {
        let lat0 = 34.87, lon0 = -118.26
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        return (0..<points).map { i in
            let a = Double(i) / Double(points) * 2 * .pi
            return GeoPoint(lat: lat0 + radius * sin(a) / mLat, lon: lon0 + radius * cos(a) / mLon)
        }
    }

    func testProgressIsMonotonicWithinALapAndWrapsAtTheLine() {
        let line = circle()
        let sim = TrackDriveSimulator(centerline: line)
        var progress = TrackProgress(centerline: line)

        var previous: Double?
        var wraps = 0
        var t = 0.0
        while t < sim.lapTime * 3 {
            let sample = sim.sample(atElapsed: t)
            let fix = progress.locate(lat: sample.position.lat, lon: sample.position.lon)
            let s = try! XCTUnwrap(fix).s
            if let previous {
                if s < previous { wraps += 1; XCTAssertLessThan(s, 40, "wrap lands near the line") }
                else { XCTAssertGreaterThanOrEqual(s, previous) }
            }
            XCTAssertLessThan(fix!.offsetMeters, 1.0, "simulator drives the centerline")
            previous = s
            t += 0.2
        }
        XCTAssertEqual(wraps, 2, "three laps → two wraps")
        XCTAssertEqual(progress.lapLength, sim.lapLengthMeters, accuracy: 0.01)
    }

    func testFirstFixIsAtTheOrigin() {
        let line = circle()
        let sim = TrackDriveSimulator(centerline: line)
        var progress = TrackProgress(centerline: line)
        let start = sim.sample(atElapsed: 0).position
        let fix = progress.locate(lat: start.lat, lon: start.lon)
        XCTAssertEqual(fix?.s ?? -1, 0, accuracy: 1.0)
    }

    func testOffTrackReturnsNil() {
        let line = circle()
        var progress = TrackProgress(centerline: line)
        // 100 m outside the circle
        let far = GeoPoint(lat: 34.87 + 260 / 110_540.0, lon: -118.26)
        XCTAssertNil(progress.locate(lat: far.lat, lon: far.lon))
    }

    func testRecoversAfterAGapBeyondTheSearchWindow() {
        let line = circle()
        let sim = TrackDriveSimulator(centerline: line)
        var progress = TrackProgress(centerline: line)
        let a = sim.sample(atElapsed: 1).position
        _ = progress.locate(lat: a.lat, lon: a.lon)
        // Skip well past the 60-segment window (half a lap later)
        let b = sim.sample(atElapsed: sim.lapTime * 0.5).position
        let fix = progress.locate(lat: b.lat, lon: b.lon)
        XCTAssertNotNil(fix, "global fallback must re-lock")
        XCTAssertEqual(fix?.s ?? 0, sim.lapLengthMeters * 0.5, accuracy: 25)
    }

    func testOriginFollowsTheGate() {
        let line = circle()
        // Put the gate a quarter lap around from index 0.
        let q = line.count / 4
        let gate = (a: line[q], b: line[q + 1])
        var progress = TrackProgress(centerline: line, gate: gate)
        // The line runs through the gate midpoint, so that point is s = 0;
        // line[q] itself sits ~2 m *before* it and correctly reads ≈ lapLength.
        let mid = GeoPoint(lat: (gate.a.lat + gate.b.lat) / 2, lon: (gate.a.lon + gate.b.lon) / 2)
        let fix = progress.locate(lat: mid.lat, lon: mid.lon)
        let s = fix?.s ?? -1
        XCTAssertTrue(s < 1 || s > progress.lapLength - 1, "gate midpoint is the origin, got \(s)")
        var fresh = TrackProgress(centerline: line, gate: gate)
        let atZero = fresh.locate(lat: line[0].lat, lon: line[0].lon)
        XCTAssertEqual(atZero?.s ?? 0, progress.lapLength * 0.75, accuracy: 10)
    }
}
