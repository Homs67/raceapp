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

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}
