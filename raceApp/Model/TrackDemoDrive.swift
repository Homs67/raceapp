//
//  TrackDemoDrive.swift
//  raceApp
//
//  Single source of truth for a track-following demo drive. Owns one
//  TrackDriveSimulator on a shared monotonic clock and vends both halves so they
//  agree: the phone sample (GPS/heading/speed/G) for DemoTelemetryFeed, and an
//  OBD DemoSample (RPM/speed/throttle) injected into SimulatedAdapterTransport.
//

import Foundation
import SessionKit
import ObdKit

final class TrackDemoDrive: @unchecked Sendable {

    let track: Track
    private let sim: TrackDriveSimulator
    private let start: TimeInterval

    init(track: Track, start: TimeInterval = monotonicNow()) {
        self.track = track
        self.start = start
        self.sim = TrackDriveSimulator(
            centerline: track.centerline.map { GeoPoint(lat: $0[0], lon: $0[1]) }
        )
    }

    private var elapsed: TimeInterval { monotonicNow() - start }

    /// Phone-sensor view of the drive at "now".
    func phoneSample() -> TrackDriveSimulator.Sample { sim.sample(atElapsed: elapsed) }

    /// Coherent OBD driving PIDs derived from the same instant's road speed.
    func obdSample() -> DemoSample {
        let s = sim.sample(atElapsed: elapsed)
        return DemoDrive.derive(speedMps: s.speedMps, longitudinalG: s.longitudinalG)
    }
}
