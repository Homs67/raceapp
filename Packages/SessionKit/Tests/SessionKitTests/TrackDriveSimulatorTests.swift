import Testing
import Foundation
@testable import SessionKit

struct TrackDriveSimulatorTests {

    /// A circle of radius R centred at a mid-latitude, sampled every few degrees.
    private func circle(radius: Double, points: Int = 180,
                        lat0: Double = 34.87, lon0: Double = -118.26) -> [GeoPoint] {
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        return (0..<points).map { i in
            let a = 2 * .pi * Double(i) / Double(points)
            return GeoPoint(lat: lat0 + radius * sin(a) / mLat,
                            lon: lon0 + radius * cos(a) / mLon)
        }
    }

    @Test func lapLengthMatchesCircumference() {
        let r = 60.0
        let sim = TrackDriveSimulator(centerline: circle(radius: r))
        #expect(abs(sim.lapLengthMeters - 2 * .pi * r) < 3)   // within ~0.4%
    }

    @Test func constantRadiusGivesConstantSpeedAndGripLimitedLatG() {
        let r = 60.0, grip = 1.0
        let sim = TrackDriveSimulator(centerline: circle(radius: r),
                                      config: .init(pace: 1.0, grip: grip))
        // On a pure circle the profile should settle to the grip-limited speed.
        let vExpected = (grip * 9.80665 * r).squareRoot()
        var speeds: [Double] = [], latGs: [Double] = []
        let step = sim.lapTime / 50
        for k in 1..<50 {
            let s = sim.sample(atElapsed: step * Double(k))
            speeds.append(s.speedMps); latGs.append(abs(s.lateralG))
        }
        let vAvg = speeds.reduce(0, +) / Double(speeds.count)
        #expect(abs(vAvg - vExpected) / vExpected < 0.08)      // ~grip-limited
        let gAvg = latGs.reduce(0, +) / Double(latGs.count)
        #expect(abs(gAvg - grip) < 0.15)                       // ≈ 1 g at the limit
    }

    @Test func lapsRepeatSeamlessly() {
        let sim = TrackDriveSimulator(centerline: circle(radius: 80))
        let a = sim.sample(atElapsed: 1.0)
        let b = sim.sample(atElapsed: 1.0 + sim.lapTime)      // one lap later
        #expect(a.lap == 0 && b.lap == 1)
        #expect(abs(a.position.lat - b.position.lat) < 1e-6)
        #expect(abs(a.position.lon - b.position.lon) < 1e-6)
        #expect(abs(a.speedMps - b.speedMps) < 0.5)
    }

    @Test func cornersAreSlowerThanStraights() {
        // Rounded "stadium": two straights + two tight ends → speed must vary.
        let lat0 = 34.87, lon0 = -118.26
        let mLat = 110_540.0, mLon = 111_320.0 * cos(lat0 * .pi / 180)
        var pts: [GeoPoint] = []
        let straight = 200.0, r = 30.0
        func add(_ x: Double, _ y: Double) {
            pts.append(GeoPoint(lat: lat0 + y / mLat, lon: lon0 + x / mLon))
        }
        for i in 0...20 { add(Double(i) / 20 * straight, 0) }              // bottom straight
        for i in 1..<18 { let a = -(.pi/2) + .pi * Double(i)/18; add(straight + r*cos(a), r + r*sin(a)) }
        for i in 0...20 { add(straight - Double(i)/20 * straight, 2*r) }   // top straight
        for i in 1..<18 { let a = (.pi/2) + .pi * Double(i)/18; add(r*cos(a), r + r*sin(a)) }
        let sim = TrackDriveSimulator(centerline: pts, config: .init(pace: 1.0))
        var vmin = Double.infinity, vmax = 0.0
        let step = sim.lapTime / 120
        for k in 0..<120 {
            let v = sim.sample(atElapsed: step * Double(k)).speedMps
            vmin = min(vmin, v); vmax = max(vmax, v)
        }
        #expect(vmax > vmin * 1.4)   // meaningfully faster on the straights
    }
}
