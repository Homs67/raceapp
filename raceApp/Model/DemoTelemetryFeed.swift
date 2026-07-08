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

final class DemoTelemetryFeed: @unchecked Sendable {

    private let bus: TelemetryBus
    private var task: Task<Void, Never>?

    init(bus: TelemetryBus) {
        self.bus = bus
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached { [bus] in
            let start = monotonicNowSeconds()
            // Angeles Crest-ish starting point
            var lat = 34.2537, lon = -118.1443
            var heading = 80.0
            var lastT = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let now = monotonicNowSeconds()
                let t = now - start
                let dt = now - lastT
                lastT = now

                let speedKmh = max(0, 65 + 45 * sin(t / 7.0) + 12 * sin(t / 2.3))
                let speedMps = speedKmh / 3.6
                let latG = 0.85 * sin(t / 3.5) + 0.15 * sin(t / 1.1)
                let longG = (45 / 7.0 * cos(t / 7.0) / 3.6) / 9.81 * 3.5

                heading += latG * 12 * dt
                let headingRad = heading * .pi / 180
                lat += speedMps * dt * cos(headingRad) / 111_111
                lon += speedMps * dt * sin(headingRad) / (111_111 * cos(lat * .pi / 180))

                bus.publish(.gpsLatitude, lat, at: now)
                bus.publish(.gpsLongitude, lon, at: now)
                bus.publish(.gpsSpeed, speedMps, at: now)
                bus.publish(.gpsCourse, heading.truncatingRemainder(dividingBy: 360), at: now)
                bus.publish(.gpsAltitude, 1200 + 60 * sin(t / 20), at: now)
                bus.publish(.gpsHorizontalAccuracy, 5 + 3 * sin(t / 9).magnitude, at: now)
                bus.publish(.imuAccelX, latG, at: now)
                bus.publish(.imuAccelY, longG, at: now)
                bus.publish(.imuAccelZ, 0.02 * sin(t * 3), at: now)
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
