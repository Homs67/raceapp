//
//  DashboardLiveFeed.swift
//  raceApp
//
//  The one place the dashboard reads the telemetry bus and session metrics.
//  Owns the accumulators (peak G, G trail) that used to be view state, and
//  resets them when a session starts rather than when a view appears.
//

import Foundation
import SwiftUI
import SessionKit
import ObdKit
import RaceBoxKit

@MainActor
final class DashboardLiveFeed {

    private var peakG = 0.0
    private var trail: [CGPoint] = []
    private var lastSessionId: UUID?

    nonisolated deinit {}   // see DashboardStore

    func tick(model: AppModel, now: TimeInterval, date: Date, metric: Bool) -> LiveSnapshot {
        let snapshot = model.bus.snapshot()
        let units = UnitsFormatter(metric: metric)
        var live = LiveSnapshot()

        // New session → fresh peaks.
        let sessionId = model.recording.currentSessionId
        if sessionId != lastSessionId {
            lastSessionId = sessionId
            peakG = 0
            trail = []
        }

        live.rpm = snapshot.fresh(.obd(.rpm), now: now, maxAge: 2)
        live.throttle = snapshot.fresh(.obd(.throttle), now: now, maxAge: 2)
        if let obdKmh = snapshot.fresh(.obd(.speed), now: now, maxAge: 2) {
            live.speedMps = obdKmh / 3.6
            live.speedDisplay = units.speed(fromKmh: obdKmh)
        } else if let gpsMps = snapshot.fresh(.gpsSpeed, now: now, maxAge: 3) {
            live.speedMps = gpsMps
            live.speedDisplay = units.speed(fromMps: gpsMps)
        }
        if let rpm = live.rpm, let speedMps = live.speedMps {
            live.gear = model.gearEstimator.gear(rpm: rpm, speedMps: speedMps)
        }
        live.obdHz = model.bus.obdHz(now: now)
        live.coolantC = snapshot.fresh(.obd(.coolantTemp), now: now, maxAge: 90)
        live.accelPedal = snapshot.fresh(.canAccelPedal, now: now, maxAge: 1) ?? live.throttle
        live.brake = snapshot.fresh(.canBrake, now: now, maxAge: 1)
        live.steering = snapshot.fresh(.canSteering, now: now, maxAge: 1)
        let defaults = UserDefaults.standard
        live.shift = ShiftIndicator(enabled: defaults.bool(forKey: "shiftEnabled"),
                                    shiftRPM: defaults.object(forKey: "shiftRPM") as? Double ?? 5500)

        // Prefer auto-calibrated car-frame G. Without it, raw phone axes are
        // the honest stand-in ONLY when the phone is the motion source: with a
        // logger attached they are somebody else's accelerometer, and a car
        // sitting still would swing the gauge as the phone was handled.
        if let lat = snapshot.fresh(.carLatG, now: now, maxAge: 1),
           let long = snapshot.fresh(.carLongG, now: now, maxAge: 1) {
            live.latG = lat
            live.longG = long
            live.gCalibrated = true
        } else if !model.raceBox.ownsMotion {
            live.latG = snapshot.fresh(.imuAccelX, now: now, maxAge: 1)
            live.longG = snapshot.fresh(.imuAccelY, now: now, maxAge: 1)
        }
        if let lat = live.latG, let long = live.longG {
            let combined = (lat * lat + long * long).squareRoot()
            live.combinedG = combined
            peakG = max(peakG, combined)
            trail.append(CGPoint(x: lat, y: -long))
            if trail.count > 40 { trail.removeFirst(trail.count - 40) }
        }
        live.peakG = peakG
        live.gTrail = trail

        live.altitude = snapshot.fresh(.gpsAltitude, now: now, maxAge: 10)
        live.heading = snapshot.fresh(.gpsCourse, now: now, maxAge: 10)
        live.gpsAccuracy = snapshot.fresh(.gpsHorizontalAccuracy, now: now, maxAge: 10)
        live.gpsLat = snapshot.fresh(.gpsLatitude, now: now, maxAge: 5)
        live.gpsLon = snapshot.fresh(.gpsLongitude, now: now, maxAge: 5)

        live.lap = model.metrics.lapState
        live.delta = model.metrics.delta
        live.lapProgressMeters = model.metrics.lapProgressMeters
        live.trackId = model.metrics.track?.id
        live.sectorDeltas = model.metrics.sectorDeltas
        live.currentSector = model.metrics.currentSector
        live.currentSectorDelta = model.metrics.currentSectorDelta

        if model.raceBox.state == .connected, let msg = model.raceBox.latest {
            let power: LoggerPower
            switch msg.power(for: model.raceBox.deviceInfo?.model ?? .micro) {
            case .inputVoltage(let v): power = .from(inputVolts: v)
            case .battery(let pct, let charging): power = .battery(percent: pct, charging: charging)
            }
            live.raceBox = RaceBoxLink(satellites: msg.satellites, has3DFix: msg.hasValidFix, power: power)
        }

        live.dragRun = model.metrics.dragRun
        live.dragBest = model.metrics.dragBest
        live.distanceMeters = model.recording.liveDistanceMeters
        live.obdConnected = model.connection.adapterLinkUp
        live.obdLive = model.connection.carLinkUp

        live.isRecording = model.recording.isRecording
        live.elapsed = model.recording.startedAt.map { date.timeIntervalSince($0) } ?? 0
        return live
    }
}
