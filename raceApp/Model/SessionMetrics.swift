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
    private var progress: TrackProgress?
    private var lapDelta: LapDelta?
    private let drag = DragMeter()
    private var task: Task<Void, Never>?
    private var lastGpsT: TimeInterval?
    private var lastSpeedT: TimeInterval?

    private(set) var track: Track?
    private(set) var lapState = LapTimer.State(completedLaps: 0, currentLapTime: nil,
                                               lastLapTime: nil, bestLapTime: nil, lapTimes: [])
    private(set) var dragRun = DragMeter.Run()
    private(set) var dragBest = DragMeter.Run()
    /// Seconds ahead (−) or behind (+) the session-best lap at the current
    /// point on the track; nil until a best lap exists.
    private(set) var delta: TimeInterval?
    /// Distance along the current lap from the start/finish line, metres.
    private(set) var lapProgressMeters: Double?
    /// Equal-thirds sectors: delta gained/lost inside each completed sector of
    /// the current lap, plus the live figure for the sector we're in.
    private(set) var sectorDeltas: [TimeInterval?] = [nil, nil, nil]
    private(set) var currentSector = 0
    private(set) var currentSectorDelta: TimeInterval?
    private var sectorStartDelta: TimeInterval?

    init(bus: TelemetryBus) { self.bus = bus }

    func start(track: Track?) {
        stop()
        self.track = track
        if let track, track.centerline.count >= 2 {
            let a = track.centerline[0], b = track.centerline[1]
            let sf = track.startFinish
            lap = LapTimer(gateA: (sf.a[0], sf.a[1]), gateB: (sf.b[0], sf.b[1]),
                           forwardHeading: Self.bearing(a[0], a[1], b[0], b[1]))
            let line = track.centerline.map { GeoPoint(lat: $0[0], lon: $0[1]) }
            var tp = TrackProgress(centerline: line,
                                   gate: (GeoPoint(lat: sf.a[0], lon: sf.a[1]), GeoPoint(lat: sf.b[0], lon: sf.b[1])))
            tp.reset()
            progress = tp
            lapDelta = LapDelta(lapLength: tp.lapLength)
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
        progress = nil; lapDelta = nil; delta = nil; lapProgressMeters = nil
        sectorDeltas = [nil, nil, nil]; currentSector = 0; currentSectorDelta = nil; sectorStartDelta = nil
        lapState = LapTimer.State(completedLaps: 0, currentLapTime: nil,
                                  lastLapTime: nil, bestLapTime: nil, lapTimes: [])
        dragRun = DragMeter.Run()
    }

    private func pump() {
        let snap = bus.snapshot()
        let now = monotonicNow()

        if let lap, let latR = snap[.gpsLatitude], let lonR = snap[.gpsLongitude], latR.t != lastGpsT {
            lastGpsT = latR.t
            let completed = lap.add(lat: latR.value, lon: lonR.value, t: latR.t)
            // `add` re-arms the lap clock on the crossing fix, so this state
            // already belongs to the new lap.
            let st = lap.state(now: latR.t)
            if completed, let last = st.lastLapTime {
                lapDelta?.lapCompleted(lapTime: last, isNewBest: st.bestLapTime == last)
                sectorDeltas = [nil, nil, nil]
                currentSector = 0
                currentSectorDelta = nil
                sectorStartDelta = nil
            }
            if let fix = progress?.locate(lat: latR.value, lon: lonR.value), let lapDelta {
                lapProgressMeters = fix.s
                if let elapsed = st.currentLapTime {
                    lapDelta.add(s: fix.s, elapsed: elapsed)
                    delta = lapDelta.delta
                }
                let sector = min(2, Int(fix.s / (lapDelta.lapLength / 3)))
                if sector > currentSector {
                    // Crossed into the next sector: bank the one we left.
                    if let d = delta, let start = sectorStartDelta ?? (currentSector == 0 ? 0 : nil) {
                        sectorDeltas[currentSector] = d - start
                    }
                    sectorStartDelta = delta
                    currentSector = sector
                }
                if let d = delta, let start = sectorStartDelta ?? (currentSector == 0 ? 0 : nil) {
                    currentSectorDelta = d - start
                } else {
                    currentSectorDelta = nil
                }
            }
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
