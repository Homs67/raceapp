//
//  CourseTiming.swift
//  SessionKit
//
//  Timing for both shapes of course the app knows:
//
//  - a circuit: one line, crossed once per lap;
//  - an autocross course: a start line and a separate finish line, one run
//    from the first to the second.
//
//  Gates are a centre, a direction of travel and a width — what someone
//  standing on the line with a phone actually produces. A crossing counts
//  only if the car's path cuts the gate segment AND it is moving within
//  ±60° of the gate's direction, which rejects wrong-way passes and the
//  sideways graze of a first turn that runs past the finish.
//
//  `RunTimer` is the live, stateful engine; `CourseTiming.runs` replays a
//  recorded trace through the same engine, which is how a session gets its
//  runs re-timed whenever a track's gates are edited.
//

import Foundation
import simd

public struct TimingGate: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    /// Direction cars travel through the gate, degrees clockwise from north.
    public var headingDegrees: Double
    /// Total length of the line, centred on (lat, lon).
    public var widthMeters: Double

    public init(lat: Double, lon: Double, headingDegrees: Double, widthMeters: Double) {
        self.lat = lat
        self.lon = lon
        self.headingDegrees = headingDegrees
        self.widthMeters = widthMeters
    }

    /// The two ends of the line (perpendicular to the heading).
    public var endpoints: (a: GeoPoint, b: GeoPoint) {
        let mLat = 110_540.0
        let mLon = 111_320.0 * cos(lat * .pi / 180)
        let h = headingDegrees * .pi / 180
        // Unit vector along the line = heading rotated 90°.
        let ex = cos(h), ny = -sin(h)          // east, north components
        let half = widthMeters / 2
        return (GeoPoint(lat: lat + ny * half / mLat, lon: lon + ex * half / mLon),
                GeoPoint(lat: lat - ny * half / mLat, lon: lon - ex * half / mLon))
    }

    /// Gate from two endpoints and a known direction of travel.
    public static func from(a: GeoPoint, b: GeoPoint, headingDegrees: Double) -> TimingGate {
        let mLat = 110_540.0
        let midLat = (a.lat + b.lat) / 2
        let mLon = 111_320.0 * cos(midLat * .pi / 180)
        let dx = (b.lon - a.lon) * mLon, dy = (b.lat - a.lat) * mLat
        return TimingGate(lat: midLat, lon: (a.lon + b.lon) / 2,
                          headingDegrees: headingDegrees,
                          widthMeters: max(1, (dx * dx + dy * dy).squareRoot()))
    }
}

public struct CourseLayout: Codable, Equatable, Sendable {
    public var start: TimingGate
    /// nil = a loop: the start line is also the finish, and every crossing closes a lap.
    public var finish: TimingGate?

    public init(start: TimingGate, finish: TimingGate? = nil) {
        self.start = start
        self.finish = finish
    }

    public var isLoop: Bool { finish == nil }
}

public struct TimedRun: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case lap        // circuit lap
        case run        // autocross start → finish
        case dnf        // started, never finished
    }
    public var index: Int           // 1-based, in order
    public var kind: Kind
    public var start: TimeInterval  // session time of the start crossing
    public var end: TimeInterval?
    public var id: Int { index }
    public var duration: TimeInterval? { end.map { $0 - start } }

    public init(index: Int, kind: Kind, start: TimeInterval, end: TimeInterval?) {
        self.index = index
        self.kind = kind
        self.start = start
        self.end = end
    }
}

/// Live timing against one layout. Feed GPS fixes in time order.
public final class RunTimer: @unchecked Sendable {

    public enum Phase: Equatable, Sendable {
        case waiting                         // no run in progress
        case running(since: TimeInterval)
    }

    public struct Config: Sendable {
        /// Shorter runs/laps are a car rolling back over the line, not a run.
        public var minDuration: TimeInterval = 8
        /// Point-to-point only: a run with no finish by now is a DNF.
        public var maxRunDuration: TimeInterval = 300
        /// How far off the gate's direction a crossing may be and still count.
        public var maxAngleDegrees: Double = 60
        public init() {}
    }

    public let layout: CourseLayout
    public let config: Config
    public private(set) var phase: Phase = .waiting
    public private(set) var runs: [TimedRun] = []

    private let lat0: Double, lon0: Double, mLat: Double, mLon: Double
    private struct Line { let a: SIMD2<Double>; let b: SIMD2<Double>; let forward: SIMD2<Double> }
    private let startLine: Line
    private let finishLine: Line?
    private var last: (p: SIMD2<Double>, t: TimeInterval)?

    public init(layout: CourseLayout, config: Config = Config()) {
        self.layout = layout
        self.config = config
        lat0 = layout.start.lat
        lon0 = layout.start.lon
        mLat = 110_540.0
        mLon = 111_320.0 * cos(lat0 * .pi / 180)
        let la0 = lat0, lo0 = lon0, mLa = mLat, mLo = mLon
        func line(_ g: TimingGate) -> Line {
            let e = g.endpoints
            func xy(_ p: GeoPoint) -> SIMD2<Double> { SIMD2((p.lon - lo0) * mLo, (p.lat - la0) * mLa) }
            let h = g.headingDegrees * .pi / 180
            return Line(a: xy(e.a), b: xy(e.b), forward: SIMD2(sin(h), cos(h)))
        }
        startLine = line(layout.start)
        finishLine = layout.finish.map(line)
    }

    /// Completed runs/laps plus the DNFs, in order.
    public var completed: [TimedRun] { runs }
    public var best: TimedRun? {
        runs.filter { $0.kind != .dnf }.min { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
    }

    /// Feed one fix. Returns the run that finished on it, if any.
    @discardableResult
    public func add(lat: Double, lon: Double, t: TimeInterval) -> TimedRun? {
        let p = SIMD2((lon - lon0) * mLon, (lat - lat0) * mLat)
        defer { last = (p, t) }

        // A point-to-point run that never reached the finish.
        if case .running(let since) = phase, !layout.isLoop, t - since > config.maxRunDuration {
            runs.append(TimedRun(index: runs.count + 1, kind: .dnf, start: since, end: nil))
            phase = .waiting
        }
        guard let prev = last else { return nil }

        if layout.isLoop {
            guard let at = crossing(prev, p, t, startLine) else { return nil }
            switch phase {
            case .waiting:
                phase = .running(since: at)
            case .running(let since):
                guard at - since >= config.minDuration else { return nil }
                let lap = TimedRun(index: runs.count + 1, kind: .lap, start: since, end: at)
                runs.append(lap)
                phase = .running(since: at)
                return lap
            }
            return nil
        }

        // Point to point. The finish is checked first: on a course where the
        // two lines are close, a fix pair can only finish a run in progress.
        if case .running(let since) = phase, let finishLine,
           let at = crossing(prev, p, t, finishLine), at - since >= config.minDuration {
            let run = TimedRun(index: runs.count + 1, kind: .run, start: since, end: at)
            runs.append(run)
            phase = .waiting
            return run
        }
        if let at = crossing(prev, p, t, startLine) {
            // Crossing the start again mid-run (a re-launch after a false
            // start, or the course looping past it) restarts the clock.
            phase = .running(since: at)
        }
        return nil
    }

    /// Elapsed time of the run in progress.
    public func elapsed(now: TimeInterval) -> TimeInterval? {
        if case .running(let since) = phase { return max(0, now - since) }
        return nil
    }

    private func crossing(_ prev: (p: SIMD2<Double>, t: TimeInterval), _ p: SIMD2<Double>,
                          _ t: TimeInterval, _ line: Line) -> TimeInterval? {
        guard let f = LapTimer.intersection(prev.p, p, line.a, line.b) else { return nil }
        let motion = p - prev.p
        let length = simd_length(motion)
        guard length > 0.01 else { return nil }
        let cosAngle = simd_dot(motion / length, line.forward)
        guard cosAngle >= cos(config.maxAngleDegrees * .pi / 180) else { return nil }
        return prev.t + (t - prev.t) * f
    }
}

public enum CourseTiming {
    /// Time a recorded trace against a layout. Samples must be in time order.
    public static func runs(lat: [ChannelSample], lon: [ChannelSample], layout: CourseLayout,
                            config: RunTimer.Config = RunTimer.Config()) -> [TimedRun] {
        let timer = RunTimer(layout: layout, config: config)
        var j = 0
        for latSample in lat {
            // Pair each latitude with the longitude written at the same instant.
            while j < lon.count, lon[j].t < latSample.t - 1e-6 { j += 1 }
            guard j < lon.count, abs(lon[j].t - latSample.t) < 1e-3 else { continue }
            timer.add(lat: latSample.value, lon: lon[j].value, t: latSample.t)
        }
        // A run still open when the recording ended never finished.
        var result = timer.completed
        if case .running(let since) = timer.phase, !layout.isLoop {
            result.append(TimedRun(index: result.count + 1, kind: .dnf, start: since, end: nil))
        }
        return result
    }

    /// Best completed run/lap duration.
    public static func best(_ runs: [TimedRun]) -> TimeInterval? {
        runs.filter { $0.kind != .dnf }.compactMap(\.duration).min()
    }
}
