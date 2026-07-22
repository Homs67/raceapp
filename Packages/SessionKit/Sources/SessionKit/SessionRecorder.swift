import Foundation
import ObdKit

/// Orchestrates one recording: owns the writer, tracks OBD gaps, accumulates
/// highlights, evaluates auto-stop, and finalizes the manifest.
/// Feed it samples from any source (PidPoller, PhoneSensorSuite, replays).
public actor SessionRecorder {

    public enum RecorderError: Error {
        case alreadyRecording
        case notRecording
    }

    private let store: SessionStore
    private var manifest: SessionManifest?
    private var writer: SessionWriter?
    private var accumulator = HighlightsAccumulator()
    private var autoStop = AutoStopMonitor()
    private var openObdGapStart: TimeInterval?
    private var obdSampleSeen = false
    private var lastSampleT: TimeInterval = 0
    private var lastSensorSampleT: [SessionManifest.SensorGap.Source: TimeInterval] = [:]
    private var flushTask: Task<Void, Never>?

    public init(store: SessionStore) {
        self.store = store
    }

    public var isRecording: Bool { manifest != nil }
    public var currentSessionId: UUID? { manifest?.id }
    public var currentDistanceMeters: Double { accumulator.distanceMeters }

    // MARK: - Lifecycle

    /// Start a session (R1.1). Writes the `.recording` manifest immediately so
    /// a crash one second later still leaves a recoverable session.
    @discardableResult
    public func start(
        at now: TimeInterval = monotonicNow(),
        utc: Date = Date(),
        car: SessionManifest.CarInfo? = nil,
        units: String? = nil,
        appVersion: String? = nil,
        supportedPids: [Int]? = nil,
        flushInterval: TimeInterval = 1.0
    ) throws -> UUID {
        guard manifest == nil else { throw RecorderError.alreadyRecording }
        var newManifest = SessionManifest(
            startedAtUTC: utc, startUptime: now,
            appVersion: appVersion, units: units, car: car,
            phoneOnly: true, // flips to false on the first OBD sample
            supportedPids: supportedPids
        )
        newManifest.status = .recording
        try store.create(newManifest)
        writer = try SessionWriter(sessionDirectory: store.directory(for: newManifest.id))
        manifest = newManifest
        accumulator = HighlightsAccumulator()
        autoStop = AutoStopMonitor()
        openObdGapStart = nil
        obdSampleSeen = false
        lastSampleT = now
        lastSensorSampleT = [:]

        flushTask = Task { [weak self, flushInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(flushInterval))
                await self?.flush()
            }
        }
        return newManifest.id
    }

    /// Ingest one sample from any source.
    public func ingest(channel: ChannelId, value: Double, at t: TimeInterval) async {
        guard manifest != nil, let writer else { return }
        await writer.append(channel, value: value, at: t)
        accumulator.add(channel: channel, value: value, t: t)
        lastSampleT = max(lastSampleT, t)
        noteSensorContinuity(channel: channel, at: t)

        if channel.rawValue.hasPrefix("obd.") {
            obdSampleSeen = true
            manifest?.phoneOnly = false
            autoStop.noteObdAlive(at: t)
            if let gapStart = openObdGapStart { // link came back — close the gap (R1.8)
                manifest?.obdGaps.append(.init(start: gapStart, end: t))
                openObdGapStart = nil
            }
        }
        if channel == .gpsSpeed {
            autoStop.noteSpeed(value, at: t)
        }
    }

    /// OBD link dropped (from the connection controller) — opens a gap record.
    public func obdLinkLost(at t: TimeInterval) {
        guard manifest != nil, obdSampleSeen, openObdGapStart == nil else { return }
        openObdGapStart = t
    }

    /// R1.6: the app's periodic tick asks whether the forgotten-stop rule fires.
    public func shouldAutoStop(now: TimeInterval = monotonicNow()) -> Bool {
        manifest != nil && autoStop.shouldAutoStop(now: now)
    }

    /// Flush all channel buffers at an app lifecycle boundary without ending
    /// the session. The manifest is already persisted as `.recording`, so this
    /// leaves a crash-recoverable checkpoint on disk.
    public func checkpoint() async {
        await flush()
    }

    /// Stop and finalize (R1.3). Saving is instant — data was never buffered-only.
    @discardableResult
    public func stop(at now: TimeInterval = monotonicNow()) async throws -> SessionManifest {
        guard var finalManifest = manifest, let writer else { throw RecorderError.notRecording }
        flushTask?.cancel()
        flushTask = nil

        if let gapStart = openObdGapStart { // session ends mid-dropout
            finalManifest.obdGaps.append(.init(start: gapStart, end: now))
        }
        for (source, lastT) in lastSensorSampleT {
            let threshold = Self.gapThreshold(for: source)
            if now - lastT > threshold {
                var gaps = finalManifest.sensorGaps ?? []
                gaps.append(.init(source: source, start: lastT, end: now))
                finalManifest.sensorGaps = gaps
            }
        }
        let counts = await writer.close()
        let sessionDirectory = store.directory(for: finalManifest.id)
        // Prefer disk-backed rate stats over close() counts alone.
        var summaries = ChannelStats.enrichAll(inSessionDirectory: sessionDirectory)
        if summaries.isEmpty {
            summaries = counts
                .map { SessionManifest.ChannelSummary(id: $0.key, sampleCount: $0.value) }
                .sorted { $0.id < $1.id }
        }
        finalManifest.channels = summaries
        let end = max(lastSampleT, finalManifest.startUptime)
        finalManifest.highlights = accumulator.finalize(startUptime: finalManifest.startUptime, endUptime: end)
        finalManifest.endedAtUTC = finalManifest.utcDate(forUptime: end)
        finalManifest.status = .complete
        let duration = finalManifest.highlights?.durationSeconds ?? max(0, end - finalManifest.startUptime)
        finalManifest.obdTiming = ChannelStats.obdTiming(
            inSessionDirectory: sessionDirectory, sessionDuration: duration)
        finalManifest.gForceValidation = GForceValidation.validate(sessionDirectory: sessionDirectory)
        // Preserve fields mutated on disk during the session (camera clips, sync, place).
        if let onDisk = try? store.manifest(for: finalManifest.id) {
            finalManifest.videos = onDisk.videos
            finalManifest.videoSyncOffset = onDisk.videoSyncOffset
            if finalManifest.locationName == nil {
                finalManifest.locationName = onDisk.locationName
            }
        }
        try store.save(finalManifest)

        manifest = nil
        self.writer = nil
        return finalManifest
    }

    private func flush() async {
        await writer?.flushAll()
    }

    private func noteSensorContinuity(channel: ChannelId, at t: TimeInterval) {
        guard let source = Self.sensorSource(for: channel) else { return }
        if let previous = lastSensorSampleT[source],
           t - previous > Self.gapThreshold(for: source) {
            var gaps = manifest?.sensorGaps ?? []
            gaps.append(.init(source: source, start: previous, end: t))
            manifest?.sensorGaps = gaps
        }
        lastSensorSampleT[source] = max(lastSensorSampleT[source] ?? t, t)
    }

    private static func sensorSource(for channel: ChannelId) -> SessionManifest.SensorGap.Source? {
        if channel.rawValue.hasPrefix("gps.") { return .gps }
        if channel.rawValue.hasPrefix("imu.") || channel.rawValue.hasPrefix("car.") {
            return .motion
        }
        if channel.rawValue.hasPrefix("baro.") { return .barometer }
        if channel.rawValue.hasPrefix("device.") { return .deviceHealth }
        return nil
    }

    private static func gapThreshold(for source: SessionManifest.SensorGap.Source) -> TimeInterval {
        switch source {
        case .gps, .barometer: 3
        case .motion: 0.5
        case .deviceHealth: 12
        }
    }
}
