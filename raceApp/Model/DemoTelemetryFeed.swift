//
//  DemoTelemetryFeed.swift
//  raceApp
//
//  Phone-sensor half of demo mode: synthesizes GPS/IMU/barometer channels
//  matching SimulatedAdapterTransport's drive model, so the G-meter and
//  map trace work on a desk / in App Review.
//

import Foundation
import SessionKit
import ObdKit

final class DemoTelemetryFeed: @unchecked Sendable {

    private let bus: TelemetryBus
    private let trackDrive: TrackDemoDrive?
    private var task: Task<Void, Never>?

    init(bus: TelemetryBus, trackDrive: TrackDemoDrive? = nil) {
        self.bus = bus
        self.trackDrive = trackDrive
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached { [bus, trackDrive] in
            let start = monotonicNowSeconds()
            // Open-road fallback state (used only when no track drive is supplied)
            var lat = 34.2537, lon = -118.1443, heading = 80.0
            var lastT = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let now = monotonicNowSeconds()
                let t = now - start
                let dt = now - lastT
                lastT = now

                let speedMps: Double, latG: Double, longG: Double

                if let td = trackDrive {
                    // Drive the real track centerline — the single source of truth.
                    let s = td.phoneSample()
                    lat = s.position.lat; lon = s.position.lon
                    heading = s.headingDeg
                    speedMps = s.speedMps; latG = s.lateralG; longG = s.longitudinalG
                } else {
                    // Angeles Crest-ish open-road integration.
                    let drive = DemoDrive(t: t)
                    speedMps = drive.speedMps; latG = drive.lateralG; longG = drive.longitudinalG
                    heading += latG * 12 * dt
                    let headingRad = heading * .pi / 180
                    lat += speedMps * dt * cos(headingRad) / 111_111
                    lon += speedMps * dt * sin(headingRad) / (111_111 * cos(lat * .pi / 180))
                }

                bus.publish(.gpsLatitude, lat, at: now)
                bus.publish(.gpsLongitude, lon, at: now)
                bus.publish(.gpsSpeed, speedMps, at: now)
                bus.publish(.gpsCourse, heading.truncatingRemainder(dividingBy: 360), at: now)
                bus.publish(.gpsAltitude, 1200 + 60 * sin(t / 20), at: now)
                bus.publish(.gpsHorizontalAccuracy, 5 + 3 * sin(t / 9).magnitude, at: now)
                bus.publish(.imuAccelX, latG, at: now)
                bus.publish(.imuAccelY, longG, at: now)
                bus.publish(.imuAccelZ, 0.02 * sin(t * 3), at: now)
                // Demo values are car-frame by construction — publish as calibrated
                bus.publish(.carLatG, latG, at: now)
                bus.publish(.carLongG, longG, at: now)
                bus.publish(.imuYawRate, latG * 0.6, at: now)
                bus.publish(.baroRelativeAltitude, 60 * sin(t / 20), at: now)
                bus.publish(.deviceBattery, 0.82, at: now)
                bus.publish(.deviceThermalState, 0, at: now)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private func monotonicNowSeconds() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
