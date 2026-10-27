import XCTest
@testable import SessionKit

/// Synthetic traces on a flat local grid: x east, y north, metres.
final class CourseTimingTests: XCTestCase {

    private let lat0 = 34.05, lon0 = -117.75
    private var mLat: Double { 110_540 }
    private var mLon: Double { 111_320 * cos(lat0 * .pi / 180) }

    private func geo(_ x: Double, _ y: Double) -> (lat: Double, lon: Double) {
        (lat0 + y / mLat, lon0 + x / mLon)
    }

    /// Gate centred at (x, y), cars travelling at `heading`.
    private func gate(_ x: Double, _ y: Double, heading: Double, width: Double = 15) -> TimingGate {
        let g = geo(x, y)
        return TimingGate(lat: g.lat, lon: g.lon, headingDegrees: heading, widthMeters: width)
    }

    /// Drive a polyline at constant speed, 25 Hz.
    private func drive(_ path: [(Double, Double)], speed: Double, from t0: TimeInterval = 0,
                       into timer: RunTimer) -> TimeInterval {
        var t = t0
        let dt = 0.04
        for i in 0..<(path.count - 1) {
            let (x0, y0) = path[i], (x1, y1) = path[i + 1]
            let len = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
            let steps = max(1, Int(len / (speed * dt)))
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                let g = geo(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
                timer.add(lat: g.lat, lon: g.lon, t: t)
                t += dt
            }
        }
        let g = geo(path.last!.0, path.last!.1)
        timer.add(lat: g.lat, lon: g.lon, t: t)
        return t
    }

    private func sit(at p: (Double, Double), for seconds: Double, from t0: TimeInterval, into timer: RunTimer) -> TimeInterval {
        var t = t0
        let g = geo(p.0, p.1)
        while t < t0 + seconds { timer.add(lat: g.lat, lon: g.lon, t: t); t += 0.04 }
        return t
    }

    // Start line across x at y=0 heading north; finish at y=300 heading north.
    private var autocross: CourseLayout {
        CourseLayout(start: gate(0, 0, heading: 0), finish: gate(0, 300, heading: 0))
    }

    func testStagingBehindTheLineDoesNotStartARun() {
        let timer = RunTimer(layout: autocross)
        var t = sit(at: (0, -5), for: 30, from: 0, into: timer)      // gridded behind the line
        XCTAssertEqual(timer.phase, .waiting)
        t = drive([(0, -5), (0, 310)], speed: 15, from: t, into: timer)
        XCTAssertEqual(timer.completed.count, 1)
        let run = timer.completed[0]
        XCTAssertEqual(run.kind, .run)
        // 300 m at 15 m/s = 20 s, regardless of the 30 s spent staged.
        XCTAssertEqual(run.duration ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(run.start, 30 + 5.0 / 15, accuracy: 0.1)
    }

    func testFirstTurnGrazingTheFinishSidewaysIsIgnored() {
        // Course leaves the start, swings east straight across the finish
        // line's extension... then comes back north through the finish.
        let layout = CourseLayout(start: gate(0, 0, heading: 0),
                                  finish: gate(30, 40, heading: 0, width: 20))
        let timer = RunTimer(layout: layout)
        _ = drive([(0, -5), (0, 40), (60, 40), (60, 100), (30, 100), (30, 20), (30, 60)],
                  speed: 12, into: timer)
        // Eastward pass at y=40 crosses the finish segment at 90° → ignored;
        // southward pass is wrong-way → ignored; final northward pass counts.
        XCTAssertEqual(timer.completed.count, 1)
        XCTAssertEqual(timer.completed.first?.kind, .run)
        let expected = (40.0 + 60 + 60 + 30 + 80 + 20) / 12   // from the start line
        XCTAssertEqual(timer.completed.first?.duration ?? 0, expected, accuracy: 0.2)
    }

    func testWrongWayAndFinishBeforeStartAreIgnored() {
        let timer = RunTimer(layout: autocross)
        // Drive south through the finish then the start: both wrong way.
        _ = drive([(0, 320), (0, -20)], speed: 10, into: timer)
        XCTAssertTrue(timer.completed.isEmpty)
        XCTAssertEqual(timer.phase, .waiting)
        // Northbound through the finish only (start never crossed): no run.
        let timer2 = RunTimer(layout: autocross)
        _ = drive([(0, 200), (0, 320)], speed: 10, into: timer2)
        XCTAssertTrue(timer2.completed.isEmpty)
    }

    func testRunWithoutFinishBecomesDNF() {
        let timer = RunTimer(layout: autocross)
        var t = drive([(0, -5), (0, 100)], speed: 10, into: timer)     // started, wandered off
        t = sit(at: (0, 100), for: 320, from: t, into: timer)
        XCTAssertEqual(timer.completed.map(\.kind), [.dnf])
        XCTAssertEqual(timer.phase, .waiting)
        // Next attempt is a clean run, numbered 2.
        t = drive([(0, 100), (0, -10)], speed: 10, from: t, into: timer)   // back to grid (wrong way)
        _ = drive([(0, -10), (0, 310)], speed: 15, from: t, into: timer)
        XCTAssertEqual(timer.completed.map(\.kind), [.dnf, .run])
        XCTAssertEqual(timer.completed.last?.index, 2)
    }

    func testLoopFirstCrossingStartsLapOneNotTheFirstFix() {
        // Square 100 m on a side; line on the west side heading north.
        let layout = CourseLayout(start: gate(0, 50, heading: 0))
        let timer = RunTimer(layout: layout)
        var t = sit(at: (0, 10), for: 60, from: 0, into: timer)   // pit lane wait
        let lap: [(Double, Double)] = [(0, 10), (0, 100), (100, 100), (100, 0), (0, 0), (0, 10)]
        for _ in 0..<3 { t = drive(lap, speed: 20, from: t, into: timer) }
        _ = drive([(0, 10), (0, 60)], speed: 20, from: t, into: timer)
        XCTAssertEqual(timer.completed.count, 3)
        for l in timer.completed {
            XCTAssertEqual(l.kind, .lap)
            XCTAssertEqual(l.duration ?? 0, 400.0 / 20, accuracy: 0.2)
        }
    }

    func testOfflineReplayMatchesLiveTimer() {
        let live = RunTimer(layout: autocross)
        var lat: [ChannelSample] = [], lon: [ChannelSample] = []
        let probe = RunTimer(layout: autocross)
        // Record what we feed so the offline path sees the same fixes.
        final class Tap { var fixes: [(Double, Double, Double)] = [] }
        let tap = Tap()
        func feed(_ path: [(Double, Double)], speed: Double, from t0: Double) -> Double {
            var t = t0
            for i in 0..<(path.count - 1) {
                let (x0, y0) = path[i], (x1, y1) = path[i + 1]
                let len = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
                let steps = max(1, Int(len / (speed * 0.04)))
                for s in 0..<steps {
                    let f = Double(s) / Double(steps)
                    let g = geo(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
                    tap.fixes.append((g.lat, g.lon, t)); live.add(lat: g.lat, lon: g.lon, t: t)
                    t += 0.04
                }
            }
            return t
        }
        var t = feed([(0, -5), (0, 310)], speed: 14, from: 0)
        t = feed([(0, 310), (0, -10)], speed: 14, from: t)
        _ = feed([(0, -10), (0, 310)], speed: 16, from: t)
        for (la, lo, tt) in tap.fixes {
            lat.append(ChannelSample(t: tt, value: la)); lon.append(ChannelSample(t: tt, value: lo))
        }
        _ = probe
        let offline = CourseTiming.runs(lat: lat, lon: lon, layout: autocross)
        XCTAssertEqual(offline, live.completed)
        XCTAssertEqual(offline.count, 2)
        XCTAssertEqual(CourseTiming.best(offline) ?? 0, 300.0 / 16, accuracy: 0.1)
    }

    private func trace(_ path: [(Double, Double)], speed: Double) -> (lat: [ChannelSample], lon: [ChannelSample]) {
        var lat: [ChannelSample] = [], lon: [ChannelSample] = []
        var t = 0.0
        for i in 0..<(path.count - 1) {
            let (x0, y0) = path[i], (x1, y1) = path[i + 1]
            let len = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
            let steps = max(1, Int(len / (speed * 0.04)))
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                let g = geo(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
                lat.append(ChannelSample(t: t, value: g.lat)); lon.append(ChannelSample(t: t, value: g.lon))
                t += 0.04
            }
        }
        return (lat, lon)
    }

    func testMatcherPicksTheCourseWhoseGatesWereDriven() {
        // Same lot, two events. September's course runs north along x=0;
        // October's runs east along y=50. Today's drive is October's course.
        let sep = CourseMatcher.Candidate(
            id: "sep", layout: CourseLayout(start: gate(0, 0, heading: 0), finish: gate(0, 200, heading: 0)),
            createdAt: Date(timeIntervalSince1970: 1_757_000_000))
        let oct = CourseMatcher.Candidate(
            id: "oct", layout: CourseLayout(start: gate(-20, 50, heading: 90), finish: gate(180, 50, heading: 90)),
            createdAt: Date(timeIntervalSince1970: 1_761_000_000))
        let drive = trace([(-30, 50), (190, 50)], speed: 14)
        let match = CourseMatcher.best([sep, oct], lat: drive.lat, lon: drive.lon,
                                       sessionDate: Date(timeIntervalSince1970: 1_761_100_000))
        XCTAssertEqual(match?.id, "oct")
        XCTAssertEqual(match?.runs.count, 1)
    }

    func testMatcherBreaksTiesByDateAndIgnoresFarTracks() {
        let layout = CourseLayout(start: gate(0, 0, heading: 0), finish: gate(0, 200, heading: 0))
        let old = CourseMatcher.Candidate(id: "old", layout: layout, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let new = CourseMatcher.Candidate(id: "new", layout: layout, createdAt: Date(timeIntervalSince1970: 1_761_000_000))
        let farGate = gate(0, 50_000, heading: 0)
        let far = CourseMatcher.Candidate(id: "far", layout: CourseLayout(start: farGate), createdAt: nil)
        let drive = trace([(0, -5), (0, 210)], speed: 14)
        let match = CourseMatcher.best([far, old, new], lat: drive.lat, lon: drive.lon,
                                       sessionDate: Date(timeIntervalSince1970: 1_761_050_000))
        XCTAssertEqual(match?.id, "new")
        XCTAssertNil(CourseMatcher.best([far], lat: drive.lat, lon: drive.lon, sessionDate: Date()))
    }

    func testManualAssignmentSurvivesAutoMatching() {
        typealias Ref = SessionManifest.TrackRef
        let manual = Ref(id: "x", nameSnapshot: "X", assignedBy: .manual, layout: nil, timedAgainst: nil, runs: [])
        let auto = Ref(id: "y", nameSnapshot: "Y", assignedBy: .auto, layout: nil, timedAgainst: nil, runs: [])
        XCTAssertFalse(Ref.autoMatchMayReplace(manual))
        XCTAssertTrue(Ref.autoMatchMayReplace(auto))
        XCTAssertTrue(Ref.autoMatchMayReplace(nil))
    }

    func testGateEndpointsRoundTrip() {
        let g = gate(10, 20, heading: 45, width: 20)
        let e = g.endpoints
        let back = TimingGate.from(a: e.a, b: e.b, headingDegrees: 45)
        XCTAssertEqual(back.lat, g.lat, accuracy: 1e-9)
        XCTAssertEqual(back.lon, g.lon, accuracy: 1e-9)
        XCTAssertEqual(back.widthMeters, 20, accuracy: 0.01)
    }
}
