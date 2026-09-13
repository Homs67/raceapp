//
//  TrackProgress.swift
//  SessionKit
//
//  Projects a GPS fix onto a track centerline to get distance-along-lap `s`.
//  This is the position index a lap delta needs and LapTimer never had: the
//  timer only knows "did we cross the gate", not "where on the lap are we".
//
//  The centerline's cumulative distance starts at index 0. On every bundled
//  track the start/finish gate midpoint sits on centerline[0] (verified to
//  0.1 m), but the origin is re-anchored to the gate at init so it follows the
//  gate if a track file is ever re-cut.
//

import Foundation
import simd

public struct TrackProgress: Sendable {

    public struct Fix: Equatable, Sendable {
        /// Metres along the lap from the start/finish line, in [0, lapLength).
        public let s: Double
        /// Perpendicular distance from the centerline (m) — the honesty channel.
        public let offsetMeters: Double
        public let segment: Int
    }

    public let lapLength: Double
    /// Beyond this the fix is treated as off-track (pit lane, parking) → nil.
    public var maxOffsetMeters: Double = 30
    /// Search window around the last known segment; ≈240 m ahead at 4 m spacing.
    public var searchAheadSegments: Int = 60
    public var searchBehindSegments: Int = 5

    private let xy: [SIMD2<Double>]
    private let segLength: [Double]
    private let cumulative: [Double]        // cumulative[i] = distance at point i, from the gate
    private let lat0: Double
    private let lon0: Double
    private let mLat: Double
    private let mLon: Double
    private var lastSegment: Int?
    private var lastS: Double?

    public init(centerline: [GeoPoint], gate: (a: GeoPoint, b: GeoPoint)? = nil) {
        precondition(centerline.count >= 3, "centerline too short")
        var p = centerline
        if let f = p.first, let l = p.last,
           abs(f.lat - l.lat) < 1e-6, abs(f.lon - l.lon) < 1e-6 { p.removeLast() }
        let n = p.count

        lat0 = p.reduce(0) { $0 + $1.lat } / Double(n)
        lon0 = p.reduce(0) { $0 + $1.lon } / Double(n)
        mLat = 110_540.0
        mLon = 111_320.0 * cos(lat0 * .pi / 180)
        let mLatV = mLat, mLonV = mLon, la0 = lat0, lo0 = lon0
        func project(_ g: GeoPoint) -> SIMD2<Double> {
            SIMD2((g.lon - lo0) * mLonV, (g.lat - la0) * mLatV)
        }
        let pts = p.map(project)

        var lengths = [Double](repeating: 0, count: n)
        for i in 0..<n { lengths[i] = simd_length(pts[(i + 1) % n] - pts[i]) }
        let total = lengths.reduce(0, +)

        // Anchor s = 0 at the gate midpoint when one is given; index 0 otherwise.
        var originS = 0.0
        if let gate {
            let mid = project(GeoPoint(lat: (gate.a.lat + gate.b.lat) / 2, lon: (gate.a.lon + gate.b.lon) / 2))
            var best = (d: Double.infinity, s: 0.0)
            var acc = 0.0
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % n]
                let ab = b - a
                let l2 = simd_length_squared(ab)
                let t = l2 < 1e-9 ? 0 : max(0, min(1, simd_dot(mid - a, ab) / l2))
                let d = simd_length(mid - (a + ab * t))
                if d < best.d { best = (d, acc + lengths[i] * t) }
                acc += lengths[i]
            }
            originS = best.s
        }

        var cum = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n {
            var v = acc - originS
            if v < 0 { v += total }
            cum[i] = v
            acc += lengths[i]
        }

        xy = pts
        segLength = lengths
        cumulative = cum
        lapLength = total
    }

    public mutating func reset() {
        lastSegment = nil
        lastS = nil
    }

    /// Locate a fix on the lap. Windowed around the previous segment; falls back
    /// to a full search on the first fix or after a long gap.
    public mutating func locate(lat: Double, lon: Double) -> Fix? {
        let p = SIMD2((lon - lon0) * mLon, (lat - lat0) * mLat)
        let n = xy.count

        func nearest(in candidates: [Int]) -> (segment: Int, t: Double, d: Double)? {
            var best: (Int, Double, Double)?
            for i in candidates {
                let a = xy[i], b = xy[(i + 1) % n]
                let ab = b - a
                let l2 = simd_length_squared(ab)
                let t = l2 < 1e-9 ? 0 : max(0, min(1, simd_dot(p - a, ab) / l2))
                let d = simd_length(p - (a + ab * t))
                if best == nil || d < best!.2 { best = (i, t, d) }
            }
            return best
        }

        var hit: (segment: Int, t: Double, d: Double)?
        if let last = lastSegment {
            let window = (-searchBehindSegments...searchAheadSegments).map { (last + $0 + n) % n }
            hit = nearest(in: window)
        }
        if hit == nil || hit!.d > maxOffsetMeters {
            hit = nearest(in: Array(0..<n))
        }
        guard let h = hit, h.d <= maxOffsetMeters else { return nil }

        var s = cumulative[h.segment] + segLength[h.segment] * h.t
        s = s.truncatingRemainder(dividingBy: lapLength)
        if s < 0 { s += lapLength }

        // GPS jitter near the line must not read as driving backwards; a large
        // backwards step is only legitimate as the wrap at the gate.
        if let prev = lastS {
            let back = prev - s
            let isWrap = s < 50 && prev > lapLength - 100
            if back > 50, !isWrap { return nil }
        }

        lastSegment = h.segment
        lastS = s
        return Fix(s: s, offsetMeters: h.d, segment: h.segment)
    }
}
