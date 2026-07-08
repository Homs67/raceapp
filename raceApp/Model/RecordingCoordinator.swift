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
    /// Bumped whenever the sessions list should refresh.
    private(set) var sessionsVersion = 0

    let store: SessionStore
    private let bus: TelemetryBus
    private var recorder: SessionRecorder?
    private var ingestTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var ingestContinuation: AsyncStream<(ChannelId, Double, TimeInterval)>.Continuation?

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

    func start(car: SessionManifest.CarInfo?, metricUnits: Bool, supportedPids: [Int]) async {
        guard !isRecording else { return }
        let recorder = SessionRecorder(store: store)
        do {
            _ = try await recorder.start(
                car: car,
                units: metricUnits ? "metric" : "imperial",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                supportedPids: supportedPids.isEmpty ? nil : supportedPids
            )
        } catch {
            return
        }
        self.recorder = recorder

        let (stream, continuation) = AsyncStream.makeStream(
            of: (ChannelId, Double, TimeInterval).self,
            bufferingPolicy: .unbounded
        )
        ingestContinuation = continuation
        ingestTask = Task.detached {
            for await (channel, value, t) in stream {
                await recorder.ingest(channel: channel, value: value, at: t)
            }
        }
        bus.setRecordingTap { channel, value, t in
            continuation.yield((channel, value, t))
        }

        isRecording = true
        startedAt = Date()
        applyIdleTimerPolicy()

        // R1.6 tick — every 15 s ask the recorder whether the forgotten-stop rule fires
        autoStopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, let recorder = self.recorder else { return }
                if await recorder.shouldAutoStop() {
                    await self.stop(auto: true)
                    return
                }
            }
        }
    }

    /// The connection controller reports adapter loss so gaps get marked (R1.8).
    func noteObdLinkLost() {
        guard let recorder else { return }
        Task { await recorder.obdLinkLost(at: monotonicUptime()) }
    }

    // MARK: - Stop (R1.3 / R1.6)

    func stop(auto: Bool = false) async {
        guard isRecording, let recorder else { return }
        bus.setRecordingTap(nil)
        ingestContinuation?.finish()
        ingestContinuation = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        ingestTask = nil

        let snapshot = bus.snapshot()
        let manifest = try? await recorder.stop()
        self.recorder = nil
        isRecording = false
        startedAt = nil
        applyIdleTimerPolicy()
        sessionsVersion += 1

        if auto, let manifest {
            postAutoStopNotification(duration: manifest.highlights?.durationSeconds ?? 0)
        }
        if let manifest,
           let lat = snapshot[.gpsLatitude]?.value,
           let lon = snapshot[.gpsLongitude]?.value {
            geocodeAndSave(manifest: manifest, latitude: lat, longitude: lon)
        }
    }

    func sessionUpdated() {
        sessionsVersion += 1
    }

    func applyIdleTimerPolicy() {
        let keepAwake = UserDefaults.standard.bool(forKey: "keepScreenAwake")
        UIApplication.shared.isIdleTimerDisabled = isRecording && keepAwake
    }

    // MARK: - Location name (R4.1)

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

    private func monotonicUptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
