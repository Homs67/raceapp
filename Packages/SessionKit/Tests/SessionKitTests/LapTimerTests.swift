import Testing
import Foundation
@testable import SessionKit

struct LapTimerTests {

    private let lat0 = 34.87, lon0 = -118.26
    private var mLat: Double { 110_540.0 }
    private var mLon: Double { 111_320.0 * cos(lat0 * .pi / 180) }

    private func circle(radius r: Double, points: Int = 240) -> [GeoPoint] {
        (0..<points).map { i in
            let a = 2 * .pi * Double(i) / Double(points)
            return GeoPoint(lat: lat0 + r * sin(a) / mLat, lon: lon0 + r * cos(a) / mLon)
        }
    }

    @Test func intersectionDetectsCrossing() {
        // Movement south→north across a west–east gate at y=0.
        let hit = LapTimer.intersection(SIMD2<Double>(0, -5), SIMD2<Double>(0, 5),
                                        SIMD2<Double>(-10, 0), SIMD2<Double>(10, 0))
        #expect(hit != nil)
        #expect(abs((hit ?? 0) - 0.5) < 0.01)   // crosses halfway
        // Parallel, no crossing.
        #expect(LapTimer.intersection(SIMD2<Double>(0, 1), SIMD2<Double>(10, 1),
                                      SIMD2<Double>(-10, 0), SIMD2<Double>(10, 0)) == nil)
    }

    @Test func countsLapsAroundACircleWithPlausibleTimes() {
        let r = 80.0
        let pts = circle(radius: r)
        let sim = TrackDriveSimulator(centerline: pts, config: .init(pace: 0.9))
        // Gate across the track at pts[0] (car passes going ~north there).
        let gate = LapTimer(
            gateA: (lat: lat0, lon: lon0 + (r - 20) / mLon),
            gateB: (lat: lat0, lon: lon0 + (r + 20) / mLon),
            forwardHeading: 0, minLapSeconds: 5)
        var completed = 0
        let dt = 0.2
        let total = sim.lapTime * 3.4
        var t = 0.0
        while t <= total {
            let s = sim.sample(atElapsed: t)
            if gate.add(lat: s.position.lat, lon: s.position.lon, t: t) { completed += 1 }
            t += dt
        }
        let st = gate.state(now: total)
        #expect(st.completedLaps == 3)
        #expect(completed == 3)
        // Each detected lap should be close to the simulator's lap time.
        for lap in st.lapTimes {
            #expect(abs(lap - sim.lapTime) / sim.lapTime < 0.1)
        }
        #expect(st.bestLapTime != nil && st.lastLapTime != nil)
    }

    @Test func ignoresWrongWayCrossings() {
        // Gate west–east at y=0; forward = north (heading 0). Cross going SOUTH.
        let gate = LapTimer(gateA: (lat: lat0 + 0.0002, lon: lon0),
                            gateB: (lat: lat0 - 0.0002, lon: lon0),
                            forwardHeading: 0, minLapSeconds: 1)
        // Wait — that gate is north–south; make a west–east gate instead.
        let g = LapTimer(gateA: (lat: lat0, lon: lon0 - 0.0002),
                         gateB: (lat: lat0, lon: lon0 + 0.0002),
                         forwardHeading: 0, minLapSeconds: 1)
        _ = gate
        // Travel south (decreasing lat) across the gate → should NOT count.
        _ = g.add(lat: lat0 + 0.0005, lon: lon0, t: 0)
        let crossed = g.add(lat: lat0 - 0.0005, lon: lon0, t: 1)
        #expect(crossed == false)
    }

    @Test func debounceBlocksRapidRecrossing() {
        let g = LapTimer(gateA: (lat: lat0, lon: lon0 - 0.0002),
                         gateB: (lat: lat0, lon: lon0 + 0.0002),
                         forwardHeading: 0, minLapSeconds: 10)
        _ = g.add(lat: lat0 - 0.0005, lon: lon0, t: 0)   // arm
        _ = g.add(lat: lat0 + 0.0005, lon: lon0, t: 1)   // first crossing (starts lap)
        _ = g.add(lat: lat0 - 0.0005, lon: lon0, t: 2)   // back (wrong way anyway)
        let quick = g.add(lat: lat0 + 0.0005, lon: lon0, t: 3)   // within 10 s of last
        #expect(quick == false)
        #expect(g.state(now: 3).completedLaps == 0)
    }
}
