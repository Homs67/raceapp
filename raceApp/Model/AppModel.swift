//
//  AppModel.swift
//  raceApp
//
//  Composition root: bus + store + connection + recording + phone sensors.
//

import Foundation
import SwiftUI
import UIKit
import SessionKit

@MainActor @Observable
final class AppModel {

    let bus = TelemetryBus()
    let store = SessionStore.standard()
    let connection: ConnectionController
    let recording: RecordingCoordinator
    let camera = SessionCameraRecorder()
    let gearEstimator = GearEstimator()
    let metrics: SessionMetrics
    private(set) var backgroundLocationStatus: PhoneSensorSuite.BackgroundLocationStatus = .notDetermined
    /// When Always Location is unavailable, keep the screen awake for the
    /// active session so iOS cannot suspend phone-only capture.
    private(set) var forceScreenAwakeForSession = false
    /// Full-screen live dashboard is expanded over Sessions (wireframe).
    var dashboardExpanded = false
    /// Settings / Debug sheets presented from Sessions toolbar.
    var showSettings = false
    var showDebug = false
    /// Optional deep-link inside Debug (`health`, `diagnostics`, `tracks`).
    var debugRoute: String?

    private let sensors = PhoneSensorSuite()
    private var launched = false

    init() {
        let bus = self.bus
        connection = ConnectionController(bus: bus)
        recording = RecordingCoordinator(store: store, bus: bus)
        metrics = SessionMetrics(bus: bus)
        connection.onObdLinkLost = { [recording] in
            recording.noteObdLinkLost()
        }
        sensors.onBackgroundLocationStatusChange = { [weak self] status in
            self?.backgroundLocationStatus = status
        }
        recording.beforeStop = { [weak self] in
            guard let self else { return }
            let sessionId = self.recording.currentSessionId
            var clips = await self.camera.stopForSessionEnd()
            if let sessionId {
                let directory = self.store.directory(for: sessionId)
                let known = Set(clips.map(\.fileName))
                let orphans = self.camera.recoverOrphanClips(sessionDirectory: directory)
                    .filter { !known.contains($0.fileName) }
                clips.append(contentsOf: orphans)
                self.appendCameraClips(clips, to: sessionId)
            }
        }
        recording.onRecordingDidStop = { [weak self] in
            self?.metrics.stop()
            self?.sensors.endRecordingActivity()
            self?.forceScreenAwakeForSession = false
            self?.dashboardExpanded = false
            self?.applyRecordingIdlePolicy()
        }
        recording.onEnterBackgroundWhileRecording = { [weak self] in
            self?.sensors.enterBackgroundRecordingMode()
        }
        backgroundLocationStatus = sensors.backgroundLocationStatus
    }

    func onLaunch() {
        guard !launched else { return }
        launched = true
        recording.recoverAtLaunch()
        sensors.requestPermissions()
        sensors.start { [bus] channel, value, t in
            bus.publish(channel, value, at: t)
        }
        connection.onLaunch()
        #if DEBUG
        // Synthesize dashcam-style test clips for the latest session
        if CommandLine.arguments.contains("-make-test-videos") {
            Task {
                if let latest = store.list().first {
                    await DebugVideoFactory.populate(manifest: latest, store: store)
                    recording.sessionUpdated()
                }
            }
        }
        // Dev/screenshot hooks: `simctl launch ... -demo [-record] [-shift-demo]`
        if CommandLine.arguments.contains("-shift-demo") {
            UserDefaults.standard.set(true, forKey: "shiftEnabled")
            UserDefaults.standard.set(5500.0, forKey: "shiftRPM") // Street mode
        }
        if CommandLine.arguments.contains("-demo") {
            // Optional `-demo-track <id>` picks the track; otherwise Laguna Seca.
            var demoTrack: Track?
            if let i = CommandLine.arguments.firstIndex(of: "-demo-track"),
               i + 1 < CommandLine.arguments.count {
                demoTrack = TrackDatabase.track(id: CommandLine.arguments[i + 1])
            }
            connection.startDemo(track: demoTrack)
            if CommandLine.arguments.contains("-record") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    startRecording(metricUnits: false)
                }
            }
        }
        #endif
    }

    func startRecording(metricUnits: Bool) {
        forceScreenAwakeForSession = !backgroundLocationStatus.supportsLockedRecording
        if forceScreenAwakeForSession {
            sensors.requestPermissions()
        }
        sensors.recalibrate() // fresh mount alignment every session
        // Track for lap timing / map: the demo's track, else auto-match by GPS.
        var track = connection.activeTrack
        if track == nil {
            let snap = bus.snapshot()
            if let lat = snap[.gpsLatitude]?.value, let lon = snap[.gpsLongitude]?.value {
                track = TrackDatabase.nearest(lat: lat, lon: lon)
            }
        }
        metrics.start(track: track)
        Task { [weak self] in
            guard let self else { return }
            let preferred = PreferredCar.load()?.asCarInfo
            let started = await recording.start(
                car: preferred ?? connection.carInfo,
                metricUnits: metricUnits,
                supportedPids: connection.supportedPidList
            )
            if started {
                sensors.beginRecordingActivity()
                applyRecordingIdlePolicy()
                dashboardExpanded = true
            } else {
                forceScreenAwakeForSession = false
                metrics.stop()
            }
        }
    }

    func applyRecordingIdlePolicy() {
        recording.applyIdleTimerPolicy(forceAwake: forceScreenAwakeForSession)
    }

    func stopRecording() {
        Task {
            await recording.stop()
        }
    }

    /// Dashboard camera control: request permission if needed, toggle ON/OFF.
    func toggleSessionCamera() {
        guard recording.isRecording, let sessionId = recording.currentSessionId else { return }
        Task {
            let directory = store.directory(for: sessionId)
            var clips = await camera.toggle(sessionId: sessionId, sessionDirectory: directory)
            let known = Set(clips.map(\.fileName))
            let orphans = camera.recoverOrphanClips(sessionDirectory: directory)
                .filter { !known.contains($0.fileName) }
            clips.append(contentsOf: orphans)
            appendCameraClips(clips, to: sessionId)
        }
    }

    /// Append finalized camera clips to the session manifest (deduped by fileName).
    private func appendCameraClips(_ clips: [VideoAsset], to sessionId: UUID) {
        guard !clips.isEmpty, var manifest = try? store.manifest(for: sessionId) else { return }
        var videos = manifest.videos ?? []
        let existing = Set(videos.map(\.fileName))
        let newClips = clips.filter { !existing.contains($0.fileName) }
        guard !newClips.isEmpty else { return }
        videos.append(contentsOf: newClips)
        manifest.videos = videos
        try? store.save(manifest)
        recording.sessionUpdated()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sensors.refreshAuthorizationStatus()
            camera.refreshAuthorizationStatus()
            sensors.enterForegroundRecordingMode()
            connection.onForeground()
            recording.applicationDidBecomeActive()
        case .background:
            recording.applicationDidEnterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func requestBackgroundLocationAccess() {
        switch backgroundLocationStatus {
        case .denied, .servicesDisabled:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .notDetermined, .whenInUse:
            sensors.requestPermissions()
        case .always:
            break
        }
    }
}
