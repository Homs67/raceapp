//
//  LiveSnapshot.swift
//  raceApp
//
//  Everything a dashboard tick can show, read once per tick. Widgets only ever
//  see this value — never the bus or SessionMetrics — so a 10 Hz redraw costs
//  one snapshot, not one per widget. Optionals are the "never a fake zero"
//  rule (R2.5): stale data is absent, not frozen.
//

import Foundation
import CoreLocation
import SessionKit

struct LiveSnapshot: Equatable {
    // Engine / speed
    var rpm: Double?
    var speedDisplay: Double?      // in the user's units
    var speedMps: Double?
    var throttle: Double?
    var gear: Int?
    var obdHz: Double = 0

    // Dynamics
    var latG: Double?
    var longG: Double?
    var gCalibrated = false
    var combinedG: Double?
    var peakG: Double = 0
    var gTrail: [CGPoint] = []

    // Position
    var altitude: Double?
    var heading: Double?
    var gpsAccuracy: Double?
    var gpsLat: Double?
    var gpsLon: Double?
    var position: CLLocationCoordinate2D? {
        guard let gpsLat, let gpsLon else { return nil }
        return CLLocationCoordinate2D(latitude: gpsLat, longitude: gpsLon)
    }

    // Lap timing
    var lap = LapTimer.State(completedLaps: 0, currentLapTime: nil, lastLapTime: nil,
                             bestLapTime: nil, lapTimes: [])
    var delta: TimeInterval?
    var lapProgressMeters: Double?
    var trackId: String?

    // Session
    var elapsed: TimeInterval = 0
    var isRecording = false

    /// Phone GPS worse than ~5 m → show tenths, not hundredths.
    var coarseTiming: Bool { (gpsAccuracy ?? 0) > 5 }
}

extension LiveSnapshot {
    /// Plausible mid-session values for widget previews (library gallery,
    /// thumbnails). Static — previews never animate.
    static func demo(track: Track?) -> LiveSnapshot {
        var s = LiveSnapshot()
        s.rpm = 6240
        s.speedDisplay = 84
        s.speedMps = 37.5
        s.throttle = 0.72
        s.gear = 3
        s.obdHz = 18
        s.latG = 0.62
        s.longG = -0.28
        s.gCalibrated = true
        s.combinedG = 0.68
        s.peakG = 1.12
        s.altitude = 812
        s.heading = 214
        s.gpsAccuracy = 3
        if let pt = track?.centerline.dropFirst(40).first, pt.count == 2 {
            s.gpsLat = pt[0]; s.gpsLon = pt[1]
        }
        s.lap = LapTimer.State(completedLaps: 2, currentLapTime: 141.34, lastLapTime: 134.43,
                               bestLapTime: 131.34, lapTimes: [136.12, 131.34, 134.43])
        s.delta = -0.34
        s.trackId = track?.id
        s.elapsed = 283
        s.isRecording = true
        return s
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}
