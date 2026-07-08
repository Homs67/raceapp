//
//  TelemetryBus.swift
//  raceApp
//
//  Central sample fan-out: sources (OBD poller, phone sensors, demo feed)
//  publish here; the UI reads throttled snapshots; the recorder taps the
//  full-rate stream while recording. Lock-based — sources run off-main.
//

import Foundation
import SessionKit
import ObdKit

struct TelemetryReading: Equatable {
    let value: Double
    let t: TimeInterval
}

final class TelemetryBus: @unchecked Sendable {

    typealias Tap = @Sendable (ChannelId, Double, TimeInterval) -> Void

    private let lock = NSLock()
    private var latest: [ChannelId: TelemetryReading] = [:]
    private var obdSampleTimes: [TimeInterval] = []
    private var tap: Tap?

    func publish(_ channel: ChannelId, _ value: Double, at t: TimeInterval) {
        lock.lock()
        latest[channel] = TelemetryReading(value: value, t: t)
        // Per-channel update rate: count one fast-loop channel, not every sample
        if channel == .obd(.rpm) {
            obdSampleTimes.append(t)
            if obdSampleTimes.count > 200 { obdSampleTimes.removeFirst(100) }
        }
        let currentTap = tap
        lock.unlock()
        currentTap?(channel, value, t)
    }

    /// Full-rate recording tap (nil to detach).
    func setRecordingTap(_ newTap: Tap?) {
        lock.lock()
        tap = newTap
        lock.unlock()
    }

    func snapshot() -> [ChannelId: TelemetryReading] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Effective OBD sample rate over the last 2 seconds.
    func obdHz(now: TimeInterval) -> Double {
        lock.lock(); defer { lock.unlock() }
        let recent = obdSampleTimes.filter { now - $0 <= 2 }
        return Double(recent.count) / 2
    }

    /// Drop OBD readings so gauges go stale immediately on adapter loss.
    func clearObdChannels() {
        lock.lock(); defer { lock.unlock() }
        latest = latest.filter { !$0.key.rawValue.hasPrefix("obd.") }
    }
}

extension [ChannelId: TelemetryReading] {
    /// Fresh value or nil — the "never a fake zero" rule (R2.5).
    func fresh(_ channel: ChannelId, now: TimeInterval, maxAge: TimeInterval) -> Double? {
        guard let reading = self[channel], now - reading.t <= maxAge else { return nil }
        return reading.value
    }

    func age(_ channel: ChannelId, now: TimeInterval) -> TimeInterval? {
        guard let reading = self[channel] else { return nil }
        return now - reading.t
    }
}
