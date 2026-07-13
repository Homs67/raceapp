//
//  Track.swift
//  raceApp
//
//  Track map database. Each track is a bundled JSON resource (raceApp/Tracks/*.json)
//  built by tools/build_tracks.py from OpenStreetMap (ODbL) geometry. Provides the
//  centerline for drawing the driven line, a start/finish gate for lap timing, and
//  curated corner apexes for segmentation.
//
//  Geometry (centerline, length) is high-confidence — validated against each track's
//  published length. Start/finish gates are approximate (`startFinish.approximate`)
//  until confirmed against a recorded lap; corner numbering is auto-derived in driving
//  order, with canonical names/numbers set on well-known corners (`officialTurn`).
//

import Foundation
import CoreLocation

struct Track: Codable, Identifiable {
    var schemaVersion: Int
    var id: String
    var name: String
    var location: String
    var country: String
    var configuration: String
    /// "clockwise" | "counterclockwise" — racing direction of the centerline.
    var direction: String
    var source: String
    var lengthMeters: Double
    var lengthMiles: Double
    var turnCount: Int
    var startFinish: Gate
    var corners: [Corner]
    /// Racing-line centerline as [lat, lon] pairs, ~4 m spacing, in driving order.
    var centerline: [[Double]]
    var cornerNumbering: String?
    var notes: String?

    struct Gate: Codable {
        var a: [Double]   // [lat, lon] — one end of the timing line
        var b: [Double]   // [lat, lon] — other end
        /// True when the gate is a best-effort placement pending on-track confirmation.
        var approximate: Bool

        var pointA: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: a[0], longitude: a[1]) }
        var pointB: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: b[0], longitude: b[1]) }
    }

    struct Corner: Codable, Identifiable {
        /// Driving-order index (1-based). Not necessarily the circuit's official number.
        var n: Int
        var name: String
        var apex: [Double]   // [lat, lon]
        /// Canonical turn number when known (e.g. "T8–8A" for Laguna's Corkscrew).
        var officialTurn: String?

        var id: Int { n }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: apex[0], longitude: apex[1]) }
    }

    var centerlineCoordinates: [CLLocationCoordinate2D] {
        centerline.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }
}

/// Loads and holds the bundled track maps. Files live in raceApp/Tracks/ and are
/// picked up automatically by the synchronized project group.
enum TrackDatabase {
    /// All bundled tracks, sorted by name. Decodes lazily on first access.
    static let all: [Track] = load()

    static func track(id: String) -> Track? { all.first { $0.id == id } }

    /// The bundled track whose centerline passes nearest to a coordinate, if any
    /// is within `maxMeters`. Used to auto-select the track at the start of a real
    /// session so the map/lap timing "just work" on a known track.
    static func nearest(lat: Double, lon: Double, maxMeters: Double = 3000) -> Track? {
        let mLon = 111_320.0 * cos(lat * .pi / 180)
        var best: (track: Track, dist: Double)?
        for t in all {
            var minSq = Double.infinity
            for c in t.centerline {
                let dx = (c[1] - lon) * mLon, dy = (c[0] - lat) * 110_540.0
                minSq = min(minSq, dx * dx + dy * dy)
            }
            let d = minSq.squareRoot()
            if d < (best?.dist ?? .infinity) { best = (t, d) }
        }
        if let best, best.dist <= maxMeters { return best.track }
        return nil
    }

    private static func load() -> [Track] {
        let decoder = JSONDecoder()
        // Bundled resources from a synchronized folder land in the bundle root.
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        var tracks: [Track] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let track = try? decoder.decode(Track.self, from: data),
                  track.schemaVersion >= 1, !track.centerline.isEmpty else { continue }
            tracks.append(track)
        }
        return tracks.sorted { $0.name < $1.name }
    }
}
