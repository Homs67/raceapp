//
//  RecordingCoordinator.swift
//  raceApp
//
//  One-button session lifecycle (R1): taps the telemetry bus at full rate into
//  SessionRecorder, ticks the auto-stop rule, geocodes the session location,
//  and posts the auto-stop notification.
//

import Foundation
import SwiftUI
import CoreLocation
import UserNotifications
import SessionKit

@MainActor @Observable
final class RecordingCoordinator {

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Active session id while `isRecording` (for camera / side channels).
    private(set) var currentSessionId: UUID?
    /// Live distance for the active session (metres), updated while recording.
    private(set) var liveDistanceMeters: Double = 0
    /// Reverse-geocoded place name from where the session started.
    private(set) var liveLocationName: String?
    /// True when GPS samples have gone quiet long enough that lock-screen
    /// capture may have been suspended by iOS.
    private(set) var samplesMayBePaused = false
    /// Bumped whenever the sessions list should refresh.
    private(set) var sessionsVersion = 0

    let store: SessionStore
    private let bus: TelemetryBus
    private var recorder: SessionRecorder?
    private var ingestTask: Task<Void, Never>?
    private var backgroundCheckpointTask: Task<Void, Never>?
    private var quietWatchTask: Task<Void, Never>?
    private var ingestContinuation: AsyncStream<(ChannelId, Double, TimeInterval)>.Continuation?
    private var didPostQuietWarning = false
    var onRecordingDidStop: (@MainActor () -> Void)?
    /// Runs before telemetry finalize (e.g. stop camera writers and append clips).
    var beforeStop: (@MainActor () async -> Void)?
    /// Re-assert GPS / motion keep-alive when the scene backgrounds.
    var onEnterBackgroundWhileRecording: (@MainActor () -> Void)?

    init(store: SessionStore, bus: TelemetryBus) {
        self.store = store
        self.bus = bus
    }

    func recoverAtLaunch() {
        let recovered = store.recoverInterruptedSessions()
        if !recovered.isEmpty { sessionsVersion += 1 }
        // Ask for notification permission once, at a calm moment — never during
        // START, which must not interrupt the dashboard (auto-stop needs it, R1.6).
        #if DEBUG
        if CommandLine.arguments.contains("-demo") { return }
        #endif
        requestNotificationPermissionIfNeeded()
    }

    // MARK: - Start (R1.1)

    @discardableResult
    func start(car: SessionManifest.CarInfo?, metricUnits: Bool, supportedPids: [Int]) async -> Bool {
        guard !isRecording else { return false }
        let recorder = SessionRecorder(store: store)
        let sessionId: UUID
        do {
            sessionId = try await recorder.start(
                car: car,
                units: metricUnits ? "metric" : "imperial",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                supportedPids: supportedPids.isEmpty ? nil : supportedPids
            )
        } catch {
            return false
        }
        self.recorder = recorder
        self.currentSessionId = sessionId

        let (stream, continuation) = AsyncStream.makeStream(
            of: (ChannelId, Double, TimeInterval).self,
            bufferingPolicy: .unbounded
        )
        ingestContinuation = continuation
        ingestTask = Task.detached { [weak self] in
            var nextAutoStopCheck =
                TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 + 15
            var nextDistancePublish =
                TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 + 0.5
            for await (channel, value, t) in stream {
                await recorder.ingest(channel: channel, value: value, at: t)
                if t >= nextDistancePublish {
                    nextDistancePublish = t + 0.5
                    let meters = await recorder.currentDistanceMeters
                    await MainActor.run { [weak self] in
                        self?.liveDistanceMeters = meters
                    }
                }
                // Check from the sample stream instead of a MainActor timer.
                // GPS/location wakes continue while locked, so forgotten-stop
                // detection remains active whenever useful telemetry arrives.
                if t >= nextAutoStopCheck {
                    nextAutoStopCheck = t + 15
                    if await recorder.shouldAutoStop(now: t) {
                        Task { @MainActor [weak self] in
                            await self?.stop(auto: true)
                        }
                        return
                    }
                }
            }
        }
        bus.setRecordingTap { channel, value, t in
            continuation.yield((channel, value, t))
        }

        isRecording = true
        startedAt = Date()
        liveDistanceMeters = 0
        liveLocationName = nil
        samplesMayBePaused = false
        didPostQuietWarning = false
        applyIdleTimerPolicy()
        startQuietSampleWatch()
        resolveStartLocationName()
        return true
    }

    /// The connection controller reports adapter loss so gaps get marked (R1.8).
    func noteObdLinkLost() {
        guard let recorder else { return }
        Task { await recorder.obdLinkLost(at: monotonicUptime()) }
    }

    // MARK: - Stop (R1.3 / R1.6)

    func stop(auto: Bool = false) async {
        guard isRecording, let recorder else { return }
        let finalizationTask = UIApplication.shared.beginBackgroundTask(
            withName: "Finish driving session", expirationHandler: nil)
        defer {
            if finalizationTask != .invalid {
                UIApplication.shared.endBackgroundTask(finalizationTask)
            }
        }

        await beforeStop?()

        quietWatchTask?.cancel()
        quietWatchTask = nil
        bus.setRecordingTap(nil)
        ingestContinuation?.finish()
        ingestContinuation = nil
        let pendingIngest = ingestTask
        ingestTask = nil
        await pendingIngest?.value

        let snapshot = bus.snapshot()
        let manifest = try? await recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        currentSessionId = nil
        liveDistanceMeters = 0
        let startedLocation = liveLocationName
        liveLocationName = nil
        samplesMayBePaused = false
        didPostQuietWarning = false
        applyIdleTimerPolicy()
        sessionsVersion += 1
        onRecordingDidStop?()

        if auto, let manifest {
            postAutoStopNotification(duration: manifest.highlights?.durationSeconds ?? 0)
        }
        if let manifest {
            if let startedLocation, manifest.locationName == nil {
                var updated = manifest
                updated.locationName = startedLocation
                try? store.save(updated)
            } else if manifest.locationName == nil,
                      let lat = snapshot[.gpsLatitude]?.value,
                      let lon = snapshot[.gpsLongitude]?.value {
                geocodeAndSave(manifest: manifest, latitude: lat, longitude: lon)
            }
        }
    }

    /// Flush pending channel blocks when the app moves to the background. This
    /// uses only finite background time; continuous execution comes from the
    /// declared location/Bluetooth modes while a drive is active.
    func applicationDidEnterBackground() {
        guard isRecording, let recorder else { return }
        onEnterBackgroundWhileRecording?()
        backgroundCheckpointTask?.cancel()
        let checkpointTask = UIApplication.shared.beginBackgroundTask(
            withName: "Checkpoint driving session", expirationHandler: nil)
        backgroundCheckpointTask = Task { [weak self] in
            await recorder.checkpoint()
            if checkpointTask != .invalid {
                UIApplication.shared.endBackgroundTask(checkpointTask)
            }
            self?.backgroundCheckpointTask = nil
        }
    }

    /// Called when returning to the foreground so a mid-drive blackout is
    /// visible immediately instead of only after export.
    func applicationDidBecomeActive() {
        guard isRecording else { return }
        refreshQuietSampleState(notify: true)
    }

    func sessionUpdated() {
        sessionsVersion += 1
    }

    /// `forceAwake` keeps the display on for the current session when Always
    /// Location is missing — the only reliable phone-only fallback.
    func applyIdleTimerPolicy(forceAwake: Bool = false) {
        let keepAwake = forceAwake || UserDefaults.standard.bool(forKey: "keepScreenAwake")
        UIApplication.shared.isIdleTimerDisabled = isRecording && keepAwake
    }

    // MARK: - Location name (R4.1)

    /// Resolve a place name as soon as recording starts (for the mini-player title).
    private func resolveStartLocationName() {
        if let lat = bus.snapshot()[.gpsLatitude]?.value,
           let lon = bus.snapshot()[.gpsLongitude]?.value {
            geocodeStartLocation(latitude: lat, longitude: lon)
            return
        }
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording, self.liveLocationName == nil else { return }
                if let lat = self.bus.snapshot()[.gpsLatitude]?.value,
                   let lon = self.bus.snapshot()[.gpsLongitude]?.value {
                    self.geocodeStartLocation(latitude: lat, longitude: lon)
                    return
                }
            }
        }
    }

    private func geocodeStartLocation(latitude: Double, longitude: Double) {
        Task { [weak self] in
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
            let name = placemark.thoroughfare ?? placemark.name ?? placemark.locality
            guard let name else { return }
            await MainActor.run {
                guard let self, self.isRecording else { return }
                self.liveLocationName = name
                if var manifest = self.store.list().first(where: { $0.status == .recording }) {
                    manifest.locationName = name
                    try? self.store.save(manifest)
                    self.sessionsVersion += 1
                }
            }
        }
    }

    private func geocodeAndSave(manifest: SessionManifest, latitude: Double, longitude: Double) {
        Task { [store] in
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
            let name = placemark.thoroughfare ?? placemark.name ?? placemark.locality
            guard let name else { return }
            var updated = manifest
            updated.locationName = name
            try? store.save(updated)
            await MainActor.run { self.sessionsVersion += 1 }
        }
    }

    // MARK: - Auto-stop notification (R1.6)

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postAutoStopNotification(duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        let minutes = Int(duration / 60)
        content.title = "Session saved"
        content.body = "Recording auto-stopped after the car shut off — \(minutes) min captured."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func startQuietSampleWatch() {
        quietWatchTask?.cancel()
        quietWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isRecording else { return }
                self.refreshQuietSampleState(notify: true)
            }
        }
    }

    private func refreshQuietSampleState(notify: Bool) {
        let now = monotonicUptime()
        let gpsAge = bus.snapshot().age(.gpsLatitude, now: now)
        let quiet = gpsAge.map { $0 > 15 } ?? true
        samplesMayBePaused = quiet && isRecording
        if quiet, notify, !didPostQuietWarning {
            didPostQuietWarning = true
            postQuietSampleWarning()
        }
        if !quiet {
            didPostQuietWarning = false
        }
    }

    private func postQuietSampleWarning() {
        let content = UNMutableNotificationContent()
        content.title = "Recording may have paused"
        content.body = "Unlock raceApp so GPS capture can resume. Keep Screen Awake helps on phone-only drives."
        let request = UNNotificationRequest(
            identifier: "recording-quiet-\(UUID().uuidString)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func monotonicUptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
