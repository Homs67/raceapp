//
//  RacingLine.swift
//  raceApp
//
//  Precomputed navigation geometry for a track: for each centerline vertex, its
//  tangent heading, a curvature-derived target speed (→ colour), whether it's a
//  braking zone, and an approximate racing line (heavily smoothed + corridor-
//  clamped centerline, which cuts corners toward the apex). Cached per track;
//  consumed by the 3D nav face. Illustrative, not a telemetry-optimised line.
//

import Foundation
import CoreLocation

struct NavPoint {
    let center: CLLocationCoordinate2D
    let racing: CLLocationCoordinate2D
    let heading: Double        // tangent, degrees (0 = N)
    let speedNorm: Double       // 0…1 across this track's target-speed range
    let braking: Bool
    let distance: Double        // metres along the lap
}

enum TrackNav {
    private static var cache: [String: [NavPoint]] = [:]

    static func points(for track: Track) -> [NavPoint] {
        if let c = cache[track.id] { return c }
        let built = build(track)
        cache[track.id] = built
        return built
    }

    private static func build(_ track: Track) -> [NavPoint] {
        let coords = track.centerlineCoordinates
        let n = coords.count
        guard n > 8 else { return [] }

        let lat0 = coords.reduce(0.0) { $0 + $1.latitude } / Double(n)
        let lon0 = coords.reduce(0.0) { $0 + $1.longitude } / Double(n)
        let mLat = 110_540.0
        let mLon = 111_320.0 * cos(lat0 * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
            SIMD2((c.longitude - lon0) * mLon, (c.latitude - lat0) * mLat)
        }
        func coord(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat0 + p.y / mLat, longitude: lon0 + p.x / mLon)
        }
        let pts = coords.map(xy)

        // Curvature radius (Menger, small window) → target speed.
        let g = 9.80665, grip = 1.0, topSpeed = 62.0
        let w = max(1, n / 200)
        var speed = [Double](repeating: topSpeed, count: n)
        var dist = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = pts[(i - w + n) % n], b = pts[i], c = pts[(i + w) % n]
            let ab = b - a, bc = c - b, ac = c - a
            let area = abs(ab.x * bc.y - ab.y * bc.x) / 2
            let la = (ab.x * ab.x + ab.y * ab.y).squareRoot()
            let lb = (bc.x * bc.x + bc.y * bc.y).squareRoot()
            let lc = (ac.x * ac.x + ac.y * ac.y).squareRoot()
            let r = area < 1e-6 ? 1e9 : (la * lb * lc) / (4 * area)
            speed[i] = min(topSpeed, (grip * g * r).squareRoot())
            if i > 0 {
                let d = pts[i] - pts[i - 1]
                dist[i] = dist[i - 1] + (d.x * d.x + d.y * d.y).squareRoot()
            }
        }
        let vMin = speed.min() ?? 0, vMax = speed.max() ?? 1
        let range = max(1, vMax - vMin)

        // Braking zone: a meaningfully slower point lies within ~40 m ahead.
        let lookahead = max(4, Int(40 / max(1, dist[min(n - 1, 10)] / 10)))
        var braking = [Bool](repeating: false, count: n)
        for i in 0..<n {
            var minAhead = speed[i]
            for k in 1...lookahead { minAhead = min(minAhead, speed[(i + k) % n]) }
            braking[i] = minAhead < speed[i] * 0.85
        }

        // Racing line: heavily smoothed centerline, clamped to a corridor.
        let corridor = 9.0, sw = max(2, n / 60)
        var racing = [SIMD2<Double>](repeating: .zero, count: n)
        for i in 0..<n {
            var acc = SIMD2<Double>.zero
            for k in -sw...sw { acc += pts[(i + k + n) % n] }
            var p = acc / Double(2 * sw + 1)
            let off = p - pts[i]
            let d = (off.x * off.x + off.y * off.y).squareRoot()
            if d > corridor { p = pts[i] + off * (corridor / d) }
            racing[i] = p
        }

        return (0..<n).map { i in
            let next = pts[(i + 1) % n]
            let heading = bearing(coords[i], coord(next))
            return NavPoint(center: coords[i], racing: coord(racing[i]), heading: heading,
                            speedNorm: (speed[i] - vMin) / range, braking: braking[i], distance: dist[i])
        }
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
