//
//  SessionMetrics.swift
//  raceApp
//
//  Live derived metrics for the recording dashboard: lap times (gate crossing)
//  and drag runs (0–60 / 0–100 / ¼-mile). Owns the pure SessionKit engines and
//  pumps them from the telemetry bus at ~5 Hz, feeding only fresh fixes.
//

import Foundation
import SessionKit
import ObdKit

@MainActor @Observable
final class SessionMetrics {

    private let bus: TelemetryBus
    private var lap: LapTimer?
    private let drag = DragMeter()
    private var task: Task<Void, Never>?
    private var lastGpsT: TimeInterval?
    private var lastSpeedT: TimeInterval?

    private(set) var track: Track?
    private(set) var lapState = LapTimer.State(completedLaps: 0, currentLapTime: nil,
                                               lastLapTime: nil, bestLapTime: nil, lapTimes: [])
    private(set) var dragRun = DragMeter.Run()
    private(set) var dragBest = DragMeter.Run()

    init(bus: TelemetryBus) { self.bus = bus }

    func start(track: Track?) {
        stop()
        self.track = track
        if let track, track.centerline.count >= 2 {
            let a = track.centerline[0], b = track.centerline[1]
            let sf = track.startFinish
            lap = LapTimer(gateA: (sf.a[0], sf.a[1]), gateB: (sf.b[0], sf.b[1]),
                           forwardHeading: Self.bearing(a[0], a[1], b[0], b[1]))
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.pump()
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        lap = nil; lastGpsT = nil; lastSpeedT = nil
        lapState = LapTimer.State(completedLaps: 0, currentLapTime: nil,
                                  lastLapTime: nil, bestLapTime: nil, lapTimes: [])
        dragRun = DragMeter.Run()
    }

    private func pump() {
        let snap = bus.snapshot()
        let now = monotonicNow()

        if let lap, let latR = snap[.gpsLatitude], let lonR = snap[.gpsLongitude], latR.t != lastGpsT {
            lastGpsT = latR.t
            lap.add(lat: latR.value, lon: lonR.value, t: latR.t)
        }
        if let lap { lapState = lap.state(now: now) }

        // Drag prefers OBD speed (km/h) and falls back to GPS (m/s).
        if let sp = snap[.obd(.speed)], sp.t != lastSpeedT {
            lastSpeedT = sp.t
            drag.add(speedMps: sp.value / 3.6, t: sp.t)
        } else if let gps = snap[.gpsSpeed], gps.t != lastSpeedT {
            lastSpeedT = gps.t
            drag.add(speedMps: gps.value, t: gps.t)
        }
        dragRun = drag.current
        dragBest = drag.best
    }

    private static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let la1 = lat1 * .pi / 180, la2 = lat2 * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
