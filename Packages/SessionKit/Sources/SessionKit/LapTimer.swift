//
//  LapTimer.swift
//  SessionKit
//
//  Detects start/finish line crossings from a stream of GPS fixes and keeps
//  lap times. Pure and stateful — fed positions live (real sessions) or from
//  the TrackDriveSimulator (demo). Crossing time is interpolated between the two
//  bracketing fixes, so timing resolution beats the raw GPS rate.
//
//  Honesty note: at 1 Hz phone GPS a car covers ~30 m between fixes at 60 mph,
//  so a crossing time still carries ~±0.3–0.5 s even interpolated — good for
//  "am I improving", not for splitting hundredths. That's the Tier-2 unlock.
//

import Foundation
import simd

public final class LapTimer: @unchecked Sendable {

    public struct State: Equatable, Sendable {
        public var completedLaps: Int
        public var currentLapTime: TimeInterval?   // since last crossing
        public var lastLapTime: TimeInterval?
        public var bestLapTime: TimeInterval?
        public var lapTimes: [TimeInterval]
        public init(completedLaps: Int, currentLapTime: TimeInterval?, lastLapTime: TimeInterval?,
                    bestLapTime: TimeInterval?, lapTimes: [TimeInterval]) {
            self.completedLaps = completedLaps
            self.currentLapTime = currentLapTime
            self.lastLapTime = lastLapTime
            self.bestLapTime = bestLapTime
            self.lapTimes = lapTimes
        }
    }

    // Local ENU projection about the gate midpoint.
    private let lat0: Double
    private let lon0: Double
    private let mLat: Double
    private let mLon: Double
    private let gateA: SIMD2<Double>
    private let gateB: SIMD2<Double>
    private let forward: SIMD2<Double>?     // unit forward direction, if known
    private let minLap: TimeInterval

    private var last: (p: SIMD2<Double>, t: TimeInterval)?
    private var lapStart: TimeInterval?
    private var laps: [TimeInterval] = []

    /// - Parameters:
    ///   - gateA/gateB: the two endpoints of the start/finish line.
    ///   - forwardHeading: track direction (deg, 0=N) at the line; when given,
    ///     crossings against the racing direction are ignored.
    ///   - minLapSeconds: debounce so a car sitting on the line can't double-count.
    public init(gateA: (lat: Double, lon: Double), gateB: (lat: Double, lon: Double),
                forwardHeading: Double? = nil, minLapSeconds: TimeInterval = 8) {
        let la0 = (gateA.lat + gateB.lat) / 2
        let lo0 = (gateA.lon + gateB.lon) / 2
        let mLatV = 110_540.0
        let mLonV = 111_320.0 * cos(la0 * .pi / 180)
        func xy(_ lat: Double, _ lon: Double) -> SIMD2<Double> {
            SIMD2((lon - lo0) * mLonV, (lat - la0) * mLatV)
        }
        self.lat0 = la0
        self.lon0 = lo0
        self.mLat = mLatV
        self.mLon = mLonV
        self.gateA = xy(gateA.lat, gateA.lon)
        self.gateB = xy(gateB.lat, gateB.lon)
        self.minLap = minLapSeconds
        self.forward = forwardHeading.map { SIMD2(sin($0 * .pi / 180), cos($0 * .pi / 180)) }
    }

    private func project(_ lat: Double, _ lon: Double) -> SIMD2<Double> {
        SIMD2((lon - lon0) * mLon, (lat - lat0) * mLat)
    }

    /// Feed a GPS fix. Returns true if a lap just completed on this fix.
    @discardableResult
    public func add(lat: Double, lon: Double, t: TimeInterval) -> Bool {
        let p = project(lat, lon)
        defer { last = (p, t) }
        guard let prev = last else {
            if lapStart == nil { lapStart = t }   // arm on first fix
            return false
        }
        guard let hit = Self.intersection(prev.p, p, gateA, gateB) else { return false }
        if let forward {                          // ignore wrong-way crossings
            if simd_dot(p - prev.p, forward) <= 0 { return false }
        }
        let crossT = prev.t + (t - prev.t) * hit
        guard let start = lapStart else { lapStart = crossT; return false }
        guard crossT - start >= minLap else { return false }   // debounce
        laps.append(crossT - start)
        lapStart = crossT
        return true
    }

    public func state(now: TimeInterval? = nil) -> State {
        State(completedLaps: laps.count,
              currentLapTime: lapStart.flatMap { s in now.map { $0 - s } },
              lastLapTime: laps.last,
              bestLapTime: laps.min(),
              lapTimes: laps)
    }

    /// Fraction along P0→P1 where it crosses segment A→B, or nil if no crossing.
    static func intersection(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>,
                             _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double? {
        let r = p1 - p0, s = b - a
        let denom = r.x * s.y - r.y * s.x
        if abs(denom) < 1e-9 { return nil }
        let qp = a - p0
        let t = (qp.x * s.y - qp.y * s.x) / denom
        let u = (qp.x * r.y - qp.y * r.x) / denom
        if t >= 0, t <= 1, u >= 0, u <= 1 { return t }
        return nil
    }
}
