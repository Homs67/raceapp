//
//  RaceBoxController.swift
//  raceApp
//
//  Owns the RaceBox link: its own CoreBluetooth central (separate profile and
//  restore identifier from the OBD adapter, so both can be connected at once),
//  the protocol session, and the live state the debug view renders.
//

import Foundation
import SwiftUI
import BleKit
import RaceBoxKit
import SessionKit

@MainActor @Observable
final class RaceBoxController {

    enum State: Equatable {
        case idle
        case scanning
        case connecting(String)
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    private enum Keys {
        static let deviceId = "racebox.uuid"
        static let deviceName = "racebox.name"
        static let useForRecording = "racebox.useForRecording"
        /// Solved car frame, per device serial.
        static func frame(_ serial: String) -> String { "racebox.frame.\(serial)" }
    }

    /// Settings toggle: let a connected RaceBox provide session position and
    /// speed instead of the phone.
    var useForRecording: Bool {
        get { UserDefaults.standard.object(forKey: Keys.useForRecording) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.useForRecording)
            publishesToBus = newValue && state.isConnected
        }
    }

    private(set) var state: State = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var deviceInfo: RaceBoxDeviceInfo?
    private(set) var latest: RaceBoxDataMessage?
    private(set) var stats = RaceBoxLinkStats()
    private(set) var recordingStatus: RaceBoxRecordingStatus?

    /// Progress of a memory dump or erase, for the memory screen.
    enum MemoryTask: Equatable {
        case idle
        case downloading(received: Int, expected: Int, drives: Int)
        case erasing(percent: Int)
        /// Downloaded and split into drives, waiting for the user to choose
        /// which to keep. Nothing is in Sessions yet.
        case preview([DrivePreview])
        case finished(drives: Int, records: Int, detail: String? = nil)
        case erased(records: Int)
        case failed(String)
    }

    /// One drive recovered from the device's log, as shown before import.
    struct DrivePreview: Identifiable, Equatable {
        struct Point: Equatable {
            let lat: Double
            let lon: Double
        }
        let id: UUID
        let startedAt: Date
        let durationSeconds: TimeInterval
        let distanceMeters: Double
        let maxSpeedMps: Double
        let records: Int
        /// Downsampled route for a thumbnail (empty when the receiver had no fix).
        let trace: [Point]
    }

    /// Drives are downloaded into a side store first, so a preview can be
    /// shown and unwanted drives thrown away without ever touching Sessions.
    static var stagingStore: SessionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(rootDirectory: base.appendingPathComponent("LiveData/racebox-staging", isDirectory: true))
    }

    /// Fired after staged drives are moved into Sessions, with their ids.
    var onSessionsImported: (@MainActor ([UUID]) -> Void)?
    private(set) var memoryTask: MemoryTask = .idle
    private var memoryWork: Task<Void, Never>?
    private(set) var lastCommandResult: String?
    private(set) var selfTestChecks: [RaceBoxSelfTest.Check] = []
    private(set) var selfTestRunAt: Date?

    /// Rolling hex log of decoded messages for the shareable diagnostic.
    private(set) var rawLog: [String] = []
    private static let rawLogLimit = 400
    /// Live messages kept for the self-test window.
    private var recentMessages: [RaceBoxDataMessage] = []

    /// Telemetry bus, set by AppModel. Publishing is gated so the debug screen
    /// can be used without a RaceBox quietly hijacking a phone-only recording.
    var bus: TelemetryBus?
    /// True when this device should feed recordings (Settings toggle + connected).
    private(set) var publishesToBus = false

    private let transport: CoreBluetoothTransport
    private var session: RaceBoxSession?
    private var scanTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var logStart = monotonicSeconds()
    /// DEBUG: drive the whole screen off the simulator instead of hardware.
    private var simulated: RaceBoxSimulatedTransport?

    var storedDeviceName: String? { UserDefaults.standard.string(forKey: Keys.deviceName) }
    private var storedDeviceId: UUID? {
        UserDefaults.standard.string(forKey: Keys.deviceId).flatMap(UUID.init(uuidString:))
    }

    /// Last decoded data message (monotonic). A Micro streams at 25 Hz, so a
    /// few seconds of silence while "connected" means the link is dead even
    /// if CoreBluetooth hasn't said so yet.
    private var lastMessageAt: TimeInterval?
    /// Connected at the BLE level but nothing has arrived for `stallAfter`.
    private(set) var dataStalled = false
    private static let stallAfter: TimeInterval = 5
    private var rescanDeadline: Task<Void, Never>?

    init() {
        transport = CoreBluetoothTransport(profile: .raceBox)
        // Without this, a Micro that loses power (car off, cable pulled)
        // stayed "Connected" in every screen until the app relaunched.
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in self?.linkLost() }
        }
    }

    /// The peripheral went away underneath a live link. Tear down, show
    /// "Not connected", and watch for it briefly — a Micro comes back the
    /// moment the car is started again.
    private func linkLost() {
        switch state {
        case .connected, .connecting: break
        default: return
        }
        liveTask?.cancel(); liveTask = nil
        statsTask?.cancel(); statsTask = nil
        if let session { Task { await session.shutdown() } }
        session = nil
        latest = nil
        dataStalled = false
        lastMessageAt = nil
        publishesToBus = false
        state = .idle
        guard storedDeviceId != nil else { return }
        scan()
        rescanDeadline?.cancel()
        rescanDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, case .scanning = self.state else { return }
            self.scanTask?.cancel()
            self.scanTask = nil
            self.transport.stopScan()
            self.state = .idle
        }
    }

    var statusText: String {
        switch state {
        case .idle: return storedDeviceName.map { "Not connected — \($0)" } ?? "Not connected"
        case .scanning: return "Scanning for RaceBox…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected:
            let name = deviceInfo?.displayName ?? "Connected"
            return dataStalled ? "\(name) — no data" : name
        case .failed(let reason): return "Failed — \(reason)"
        }
    }

    // MARK: - Connect

    /// Reconnect a remembered device at launch and on foreground, the way the
    /// OBD adapter does.
    ///
    /// Without this the logger only ever connected when its debug screen was
    /// open, so a session recorded without visiting that screen silently fell
    /// back to phone GPS — which is exactly what happened on the first real
    /// drive. Deliberately does NOT scan: someone who has never paired a
    /// RaceBox should pay nothing for the feature existing.
    func autoConnectIfRemembered() {
        guard useForRecording, case .idle = state, let id = storedDeviceId else { return }
        connect(to: id, name: storedDeviceName ?? "RaceBox")
    }

    func start() {
        guard case .idle = state else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-racebox-demo") {
            startSimulated()
            return
        }
        #endif
        if let id = storedDeviceId {
            connect(to: id, name: storedDeviceName ?? "RaceBox")
        } else {
            scan()
        }
    }

    func scan() {
        scanTask?.cancel()
        discovered = []
        state = .scanning
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.transport.scan()
                for await device in stream {
                    guard !Task.isCancelled else { return }
                    if let index = self.discovered.firstIndex(where: { $0.id == device.id }) {
                        self.discovered[index] = device
                    } else {
                        self.discovered.append(device)
                    }
                    self.discovered.sort { $0.rssi > $1.rssi }
                    // A remembered device reconnects on sight; otherwise a lone
                    // hit auto-connects so first pairing is one tap.
                    if device.id == self.storedDeviceId || self.discovered.count == 1 {
                        self.select(device)
                        return
                    }
                }
            } catch {
                self.state = .failed(Self.describe(error))
            }
        }
    }

    func select(_ device: DiscoveredAdapter) {
        UserDefaults.standard.set(device.id.uuidString, forKey: Keys.deviceId)
        UserDefaults.standard.set(device.name, forKey: Keys.deviceName)
        connect(to: device.id, name: device.name)
    }

    private func connect(to id: UUID, name: String) {
        scanTask?.cancel()
        transport.stopScan()
        state = .connecting(name)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.connect(to: id)
                let info = RaceBoxDeviceInfo(deviceInfo: await self.transport.readDeviceInfo())
                self.deviceInfo = info
                await self.attach(session: RaceBoxSession(transport: self.transport))
                self.state = .connected
                self.publishesToBus = self.useForRecording
                self.prepareFrameForSession()
                // Recording status is the first thing worth knowing on a
                // Mini S / Micro: it may already be logging on its own.
                if info.supportsStandaloneRecording { await self.refreshRecordingStatus() }
            } catch {
                self.state = .failed(Self.describe(error))
            }
        }
    }

    func disconnect() {
        scanTask?.cancel()
        liveTask?.cancel()
        statsTask?.cancel()
        scanTask = nil
        liveTask = nil
        statsTask = nil
        if let session { Task { await session.shutdown() } }
        session = nil
        simulated?.stop()
        simulated = nil
        transport.stopScan()
        transport.disconnect()
        publishesToBus = false
        state = .idle
        latest = nil
        lastMessageAt = nil
        dataStalled = false
        rescanDeadline?.cancel()
        rescanDeadline = nil
        recentMessages = []
    }

    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Keys.deviceId)
        UserDefaults.standard.removeObject(forKey: Keys.deviceName)
        deviceInfo = nil
        rawLog = []
        selfTestChecks = []
    }

    // MARK: - Stored memory

    /// Pull everything the logger has recorded on its own and turn it into
    /// app sessions.
    ///
    /// The device stores one continuous log, not files: separate drives are
    /// recovered from the start/stop markers saved alongside the data. Each
    /// run of records between markers becomes its own session, written
    /// through the ordinary recorder so imported drives get the same
    /// manifest, highlights and export path as live ones.
    ///
    /// Records are written as they arrive rather than buffered — a full
    /// memory is hundreds of thousands of messages and will not fit in RAM.
    func downloadStoredData(into store: SessionStore, car: SessionManifest.CarInfo?, units: String?) {
        guard case .idle = memoryTask, let session else { return }
        memoryWork?.cancel()
        memoryWork = Task { [weak self] in
            guard let self else { return }
            let importer = RaceBoxMemoryImporter(store: store, car: car, units: units)
            self.memoryTask = .downloading(received: 0, expected: 0, drives: 0)
            do {
                // Subscribe BEFORE asking for the dump: the device starts
                // streaming the moment it answers, and anything emitted
                // between the reply and a late subscription is gone.
                let events = await session.historyEvents
                let expected = Int(try await session.startDownload())
                let statsBefore = await session.stats
                var received = 0
                var markers = 0
                // The device's ACK is supposed to come last. If it ever comes
                // early, keep draining until the records stop for 2 s rather
                // than throwing away everything still in flight.
                let (drained, relay) = AsyncStream.makeStream(of: RaceBoxHistoryEvent.self)
                let forwarder = Task {
                    for await event in events { relay.yield(event) }
                    relay.finish()
                }
                defer { forwarder.cancel() }
                var quietTimer: Task<Void, Never>?
                var acked = false
                for await event in drained {
                    if Task.isCancelled { try? await session.cancelDownload(); break }
                    if acked {
                        quietTimer?.cancel()
                        quietTimer = Task { try? await Task.sleep(for: .seconds(2)); relay.finish() }
                    }
                    switch event {
                    case .record(let message):
                        await importer.add(message)
                        received += 1
                        if received % 25 == 0 {
                            self.memoryTask = .downloading(received: received, expected: expected,
                                                           drives: await importer.driveCount)
                        }
                    case .stateChange(let change):
                        // A marker closes the drive before it; `running` opens
                        // the next one.
                        markers += 1
                        await importer.mark(running: change.state == .running)
                    case .eraseProgress(let percent):
                        self.memoryTask = .erasing(percent: percent)
                    case .finished:
                        acked = true
                        if received >= expected { relay.finish() } else {
                            quietTimer = Task { try? await Task.sleep(for: .seconds(2)); relay.finish() }
                        }
                    }
                }
                quietTimer?.cancel()
                _ = await importer.finish()
                let statsAfter = await session.stats
                let detail = await Self.downloadAccounting(
                    expected: expected, received: received, markers: markers, acked: acked,
                    importer: importer, before: statsBefore, after: statsAfter)
                self.lastCommandResult = "Download: " + detail
                self.memoryTask = Self.previewTask(in: store, records: received, detail: detail)
            } catch {
                _ = await importer.finish()
                self.memoryTask = .failed(Self.describe(error))
            }
        }
    }

    /// Everything needed to explain an empty download from the screen alone.
    private static func downloadAccounting(expected: Int, received: Int, markers: Int, acked: Bool,
                                           importer: RaceBoxMemoryImporter,
                                           before: RaceBoxLinkStats, after: RaceBoxLinkStats) async -> String {
        var parts = ["device announced \(expected) records", "\(received) history records arrived"]
        if markers > 0 { parts.append("\(markers) start/stop markers") }
        let live = after.dataMessages - before.dataMessages
        if live > 0 { parts.append("\(live) live-data messages during the download") }
        var others: [String] = []
        for (key, count) in after.otherPackets {
            let delta = count - (before.otherPackets[key] ?? 0)
            if delta > 0 { others.append("\(key)×\(delta)") }
        }
        if !others.isEmpty { parts.append("other packets " + others.sorted().joined(separator: " ")) }
        if !acked { parts.append("no completion ACK") }
        parts.append(await importer.accounting)
        return parts.joined(separator: " · ")
    }

    /// Describe what the download produced: a preview to choose from, or
    /// "nothing" when the log held no drive worth keeping.
    private static func previewTask(in staging: SessionStore, records: Int, detail: String) -> MemoryTask {
        let previews = staging.list().map { manifest -> DrivePreview in
            let directory = staging.directory(for: manifest.id)
            let lats = ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: directory)
            let lons = ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: directory)
            let n = min(lats.count, lons.count)
            let stride = max(1, n / 300)
            var trace: [DrivePreview.Point] = []
            var i = 0
            while i < n {
                trace.append(.init(lat: lats[i].value, lon: lons[i].value))
                i += stride
            }
            let h = manifest.highlights
            return DrivePreview(id: manifest.id, startedAt: manifest.startedAtUTC,
                                durationSeconds: h?.durationSeconds ?? 0,
                                distanceMeters: h?.distanceMeters ?? 0,
                                maxSpeedMps: h?.maxSpeedMps ?? 0,
                                records: ChannelReader.sampleCount(for: .rbWallTime, inSessionDirectory: directory),
                                trace: trace)
        }
        .sorted { $0.startedAt > $1.startedAt }
        return previews.isEmpty ? .finished(drives: 0, records: records, detail: detail) : .preview(previews)
    }

    /// Move the chosen staged drives into Sessions and drop the rest.
    func importStagedDrives(_ ids: Set<UUID>, into store: SessionStore) {
        guard case .preview(let previews) = memoryTask else { return }
        let staging = Self.stagingStore
        var imported: [UUID] = []
        var records = 0
        for preview in previews {
            let from = staging.directory(for: preview.id)
            if ids.contains(preview.id) {
                let to = store.directory(for: preview.id)
                try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                if (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                    imported.append(preview.id)
                    records += preview.records
                    continue
                }
            }
            try? staging.delete(preview.id)
        }
        Self.clearStaging()
        memoryTask = .finished(drives: imported.count, records: records)
        if !imported.isEmpty { onSessionsImported?(imported) }
    }

    func discardStagedDrives() {
        Self.clearStaging()
        memoryTask = .idle
    }

    /// Leftovers from a crash mid-download are worthless without the preview
    /// that owned them.
    static func clearStaging() {
        try? FileManager.default.removeItem(at: stagingStore.rootDirectory)
    }

    /// Erase the device's memory. Three things the first version got wrong:
    /// it never listened for progress (the bar sat at 0% for minutes), it
    /// sent the erase while the Micro was still recording — which the device
    /// NACKs — and it reported the result as "Nothing to import".
    func eraseStoredData() {
        guard case .idle = memoryTask, let session else { return }
        memoryWork?.cancel()
        memoryWork = Task { [weak self] in
            guard let self else { return }
            self.memoryTask = .erasing(percent: 0)
            // Subscribe before anything is sent, or the first progress
            // notifications are routed to nobody.
            let events = await session.historyEvents
            let progress = Task { [weak self] in
                for await event in events {
                    if Task.isCancelled { return }
                    if case .eraseProgress(let percent) = event {
                        self?.memoryTask = .erasing(percent: percent)
                    }
                }
            }
            defer { progress.cancel() }
            do {
                await self.refreshRecordingStatus()
                guard let status = self.recordingStatus else {
                    throw RaceBoxError.timeout
                }
                if status.securityEnabled, !status.memoryUnlocked {
                    self.memoryTask = .failed("memory is locked — unlock it in the RaceBox app, then try again")
                    return
                }
                let before = Int(status.storedMessages)
                // The device refuses to erase while recording: pause it and
                // put the same configuration back afterwards.
                var resume: RaceBoxRecordingConfig?
                if status.isRecording {
                    resume = try? await session.recordingConfig()
                    try await session.stopRecording()
                }
                try await session.eraseMemory()
                if let resume {
                    try? await session.setRecording(resume)
                }
                await self.refreshRecordingStatus()
                if let left = self.recordingStatus?.storedMessages, left > 0 {
                    self.memoryTask = .failed("device still reports \(left) records after erasing")
                } else {
                    self.memoryTask = .erased(records: before)
                }
            } catch {
                self.memoryTask = .failed(Self.describe(error))
            }
        }
    }

    func cancelMemoryTask() {
        memoryWork?.cancel()
        memoryWork = nil
        let erasing: Bool
        if case .erasing = memoryTask { erasing = true } else { erasing = false }
        if let session {
            Task {
                if erasing { try? await session.cancelErase() } else { try? await session.cancelDownload() }
            }
        }
        if !erasing { Self.clearStaging() }
        memoryTask = .idle
    }

    func clearMemoryResult() {
        switch memoryTask {
        case .idle, .downloading, .erasing, .preview: return   // preview ends via import/discard
        default: memoryTask = .idle
        }
    }

    /// Ask the device what it is holding.
    func refreshMemoryStatus() {
        Task { await refreshRecordingStatus() }
    }

    // MARK: - Session plumbing

    private func attach(session newSession: RaceBoxSession) async {
        session = newSession
        await newSession.start()
        logStart = monotonicSeconds()
        lastLoggedAt = nil
        rawLog = []
        recentMessages = []

        liveTask = Task { [weak self] in
            guard let self, let session = self.session else { return }
            for await message in await session.liveData {
                guard !Task.isCancelled else { return }
                self.ingest(message)
            }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let session = self.session else { return }
                self.stats = await session.stats
                if let last = self.lastMessageAt, self.state == .connected {
                    self.dataStalled = monotonicSeconds() - last > Self.stallAfter
                }
            }
        }
    }

    private func ingest(_ message: RaceBoxDataMessage) {
        latest = message
        lastMessageAt = monotonicSeconds()
        dataStalled = false
        recentMessages.append(message)
        if recentMessages.count > 200 { recentMessages.removeFirst(100) }
        appendLog(message)
        publish(message)
    }

    /// Called with every valid fix: 25 Hz ground speed for the car-frame
    /// G calibration, which otherwise runs on the phone's 1 Hz GPS.
    /// `course` is nil when the receiver has no heading solution, so the phone
    /// can fill that one channel in without touching position.
    var onPositionFix: ((_ speedMps: Double, _ course: Double?, _ t: TimeInterval) -> Void)?

    /// Called for every motion sample, so the phone's own (cradle-mounted)
    /// car-frame estimate stands down for as long as this device is streaming.
    var onMotionSample: ((TimeInterval) -> Void)?

    /// True while this device is streaming into the bus: the dashboard uses
    /// it to avoid falling back to phone axes for the car's G.
    var ownsMotion: Bool { publishesToBus && state == .connected && !dataStalled }

    /// Car-frame G from the logger's own accelerometer. Separate from the
    /// phone's calibrator: different mount, different rate, its own levelling.
    private var frame = LoggerFrameTracker()
    private var lastFrameSave: TimeInterval = 0

    /// Where the phone recalibrates every session because it moves in and out
    /// of a cradle, a logger plugged into the OBD port does not move — and an
    /// OBD connector only fits one way round. So the solved frame is kept per
    /// device and restored, which is the difference between G being live
    /// immediately and being blank for the first minutes of every drive.
    /// `LoggerFrameTracker` discards a restored frame if the measured "down"
    /// says the device is somewhere else now.
    func prepareFrameForSession() {
        frame = LoggerFrameTracker()
        if let stored = storedFrame() { frame.restore(stored) }
    }

    /// Discard the stored alignment and start over — the guided flow's
    /// "recalibrate", and the escape hatch if a frame ever goes bad.
    func forgetFrameCalibration() {
        frame = LoggerFrameTracker()
        lastFrameSave = 0
        if let serial = frameKeySerial {
            UserDefaults.standard.removeObject(forKey: Keys.frame(serial))
        }
    }

    /// Progress for the calibration UI.
    var framePhase: CarFrameCalibrator.Phase { frame.phase }
    var frameQuality: CarFrameCalibrator.FitQuality? { frame.fitQuality }
    var hasStoredFrame: Bool { storedFrame() != nil }

    /// Serial identifies the device; fall back to the remembered name so one
    /// whose Device Info read failed still keeps its frame.
    private var frameKeySerial: String? {
        deviceInfo?.serialNumber ?? storedDeviceName
    }

    private func storedFrame() -> CarFrameCalibrator.Snapshot? {
        guard let serial = frameKeySerial,
              let data = UserDefaults.standard.data(forKey: Keys.frame(serial)) else { return nil }
        return try? JSONDecoder().decode(CarFrameCalibrator.Snapshot.self, from: data)
    }

    /// Writing at 25 Hz would hammer UserDefaults; the frame only improves
    /// every few seconds anyway.
    private func saveFrameIfDue(now: TimeInterval) {
        guard now - lastFrameSave > 10, let serial = frameKeySerial,
              let snapshot = frame.snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        lastFrameSave = now
        UserDefaults.standard.set(data, forKey: Keys.frame(serial))
    }

    /// Feed the telemetry bus. Position and speed go to the canonical `gps.*`
    /// channels so every existing consumer — lap timer, drag meter, highlights,
    /// graphs, video review — gets 25 Hz data with no change; `rb.*` carries
    /// what only this device provides.
    private func publish(_ m: RaceBoxDataMessage) {
        guard publishesToBus, let bus else { return }
        let t = monotonicSeconds()

        // Always useful, fix or not: these are how you diagnose a bad fix.
        bus.publish(.rbSatellites, Double(m.satellites), at: t)
        bus.publish(.rbPdop, m.pdop, at: t)
        bus.publish(.rbFixStatus, Double(m.fixStatus.rawValue), at: t)
        bus.publish(.rbGForceX, m.gForce.x, at: t)
        bus.publish(.rbGForceY, m.gForce.y, at: t)
        bus.publish(.rbGForceZ, m.gForce.z, at: t)

        // Car-frame G from this accelerometer. Fed on every packet — levelling
        // happens parked, before there is any fix to speak of. The phone is
        // told on every sample, so it stops reporting the car's G the moment
        // this device is live rather than once the alignment converges.
        onMotionSample?(t)
        if let g = frame.ingest(accel: Vector3(m.gForce.x, m.gForce.y, m.gForce.z),
                                rotationRate: Vector3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                                at: t) {
            bus.publish(.carLatG, g.latG, at: t)
            bus.publish(.carLongG, g.longG, at: t)
            saveFrameIfDue(now: t)
        }
        bus.publish(.rbRollRate, m.rotationRate.x, at: t)
        bus.publish(.rbPitchRate, m.rotationRate.y, at: t)
        bus.publish(.rbYawRate, m.rotationRate.z, at: t)
        switch m.power(for: deviceInfo?.model ?? .micro) {
        case .inputVoltage(let volts): bus.publish(.rbPower, volts, at: t)
        case .battery(let percent, _): bus.publish(.rbPower, Double(percent), at: t)
        }
        if let stamp = m.timestamp {
            bus.publish(.rbWallTime, stamp.timeIntervalSince1970, at: t)
        }

        // Position only counts once the receiver actually has a solution. A
        // cold-start packet carries confident-looking coordinates that are
        // kilometres wrong, so gate on the flags rather than plausibility.
        guard m.hasValidFix, m.coordinatesValid else { return }
        onPositionFix?(m.speedMps, m.headingValid ? m.headingDegrees : nil, t)
        frame.ingestSpeed(m.speedMps, at: t)
        bus.publish(.gpsLatitude, m.latitude, at: t)
        bus.publish(.gpsLongitude, m.longitude, at: t)
        bus.publish(.gpsSpeed, m.speedMps, at: t)
        bus.publish(.gpsAltitude, m.mslAltitude, at: t)
        bus.publish(.gpsHorizontalAccuracy, m.horizontalAccuracy, at: t)
        bus.publish(.gpsVerticalAccuracy, m.verticalAccuracy, at: t)
        bus.publish(.gpsSpeedAccuracy, m.speedAccuracyMps, at: t)
        // Course over ground is meaningless when stopped — a parked device
        // swung through 234°, 155°, 316° in the bench log. Only publish it
        // when the receiver says it has a real heading.
        if m.headingValid {
            bus.publish(.gpsCourse, m.headingDegrees, at: t)
        }
    }

    private func appendLog(_ message: RaceBoxDataMessage) {
        // One line per message would flood; log ~2 Hz, which is plenty to see
        // values move while keeping the shared file readable.
        //
        // Throttle on the ABSOLUTE clock, not on elapsed-since-connect. Storing
        // elapsed meant a reconnect reset `logStart` while this kept the old
        // session's value, so the comparison stayed negative and suppressed
        // every line until the new session outlived the previous one — a
        // reconnect after a 150 s session logged nothing for 150 s. Absolute
        // timestamps only ever move forward, so stale state can at worst emit
        // one extra line.
        let now = monotonicSeconds()
        if let last = lastLoggedAt, now - last < 0.5 { return }
        lastLoggedAt = now
        let elapsed = now - logStart
        rawLog.append(String(
            format: "%7.2fs  fix=%d sats=%02d  %.6f,%.6f  %6.2f m/s  hdg %6.2f  G %+.3f/%+.3f/%+.3f  rot %+.2f/%+.2f/%+.2f  pwr 0x%02X",
            elapsed, message.fixStatus.rawValue, message.satellites,
            message.latitude, message.longitude, message.speedMps, message.headingDegrees,
            message.gForce.x, message.gForce.y, message.gForce.z,
            message.rotationRate.x, message.rotationRate.y, message.rotationRate.z,
            message.powerByte))
        if rawLog.count > Self.rawLogLimit { rawLog.removeFirst(rawLog.count - Self.rawLogLimit) }
    }
    private var lastLoggedAt: TimeInterval?

    // MARK: - Commands

    func refreshRecordingStatus() async {
        guard let session else { return }
        do {
            recordingStatus = try await session.recordingStatus()
            lastCommandResult = nil
        } catch {
            recordingStatus = nil
            lastCommandResult = "Recording status failed — \(Self.describe(error))"
        }
    }

    func setStandaloneRecording(_ enabled: Bool, standingStarts: Bool = false) async {
        guard let session else { return }
        do {
            if enabled {
                try await session.setRecording(standingStarts ? .standingStarts : .recommended)
                lastCommandResult = "Recording started (\(standingStarts ? "standing starts" : "recommended") filters)"
            } else {
                try await session.stopRecording()
                lastCommandResult = "Recording stopped"
            }
            await refreshRecordingStatus()
        } catch {
            lastCommandResult = "Command failed — \(Self.describe(error))"
        }
    }

    // MARK: - Self-test

    func runSelfTest() {
        selfTestChecks = RaceBoxSelfTest.evaluate(messages: recentMessages, stats: stats,
                                                  model: deviceInfo?.model)
        selfTestRunAt = Date()
    }

    var selfTestSummary: (passed: Int, failed: Int, skipped: Int) {
        RaceBoxSelfTest.summary(selfTestChecks)
    }

    // MARK: - Shareable log

    private var cachedLogURL: URL?
    private var cachedLogSignature: String?

    /// URL for the share sheet. The debug view's body re-evaluates on every
    /// data message — 25 times a second — so this must not rewrite the file
    /// per frame. Regenerates only when the content actually changed (the
    /// sample log grows at ~2 Hz), otherwise hands back the cached URL.
    func logFileURL() -> URL? {
        let signature = "\(rawLog.count)|\(selfTestChecks.count)|\(selfTestRunAt?.timeIntervalSince1970 ?? 0)|\(recordingStatus?.storedMessages ?? 0)"
        if signature == cachedLogSignature, let cachedLogURL { return cachedLogURL }
        cachedLogSignature = signature
        cachedLogURL = writeLogFile()
        return cachedLogURL
    }

    func writeLogFile() -> URL? {
        var lines = ["RACEAPP · RACEBOX DEBUG",
                     Date().formatted(date: .abbreviated, time: .standard), ""]
        if let deviceInfo {
            lines.append("DEVICE")
            lines.append("  Model: \(deviceInfo.model?.rawValue ?? "unknown")")
            lines.append("  Serial: \(deviceInfo.serialNumber ?? "—")")
            lines.append("  Firmware: \(deviceInfo.firmware?.description ?? "—")")
            lines.append("  Hardware: \(deviceInfo.hardwareRevision ?? "—")")
            lines.append("  Manufacturer: \(deviceInfo.manufacturer ?? "—")")
            lines.append("  Standalone recording: \(deviceInfo.supportsStandaloneRecording)")
            lines.append("  GNSS config / NMEA (fw 3.3+): \(deviceInfo.supportsGnssConfig)")
            lines.append("")
        }
        lines.append("LINK")
        lines.append(String(format: "  rate %.1f Hz · %d packets · %d data messages",
                            stats.measuredHz, stats.packetsParsed, stats.dataMessages))
        lines.append("  checksum failures: \(stats.checksumFailures)")
        lines.append("  bytes discarded: \(stats.bytesDiscarded)")
        lines.append("  largest notification: \(stats.largestNotification) bytes")
        lines.append("")
        if let status = recordingStatus {
            lines.append("STANDALONE RECORDING")
            lines.append("  recording: \(status.isRecording)")
            lines.append("  memory: \(status.memoryLevelPercent)% · \(status.storedMessages)/\(status.memorySizeMessages) records")
            lines.append("  security: enabled=\(status.securityEnabled) unlocked=\(status.memoryUnlocked)")
            lines.append("")
        }
        if !selfTestChecks.isEmpty {
            // Stamp it: the self-test is a snapshot, so its packet counts
            // legitimately trail the live LINK figures above and shouldn't
            // read as a contradiction.
            let when = selfTestRunAt.map { Self.logTime.string(from: $0) } ?? "—"
            lines.append("SELF-TEST (run at \(when))")
            for check in selfTestChecks {
                let mark = switch check.status {
                case .pass: "PASS"
                case .fail: "FAIL"
                case .skipped: "SKIP"
                }
                lines.append("  [\(mark)] \(check.title) — \(check.detail)")
            }
            lines.append("")
        }
        lines.append("LIVE SAMPLES (\(rawLog.count) lines, ~2 Hz)")
        lines.append(contentsOf: rawLog)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raceapp-racebox-log.txt")
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Debug simulator

    #if DEBUG
    /// Runs the real session against a synthetic device — lets the debug view
    /// be exercised and screenshotted in the simulator with no hardware.
    func startSimulated() {
        disconnect()
        var t = 0.0
        let source = RaceBoxSimulatedTransport(model: .micro, rate: .hz25) {
            t += 0.04
            // Parked first, then accelerometer values consistent with the
            // speed profile: the car-frame fit needs a still period to level
            // and real dv/dt to align against, so an arbitrary oscillation
            // never leaves `calibrating`.
            let parked = 6.0
            let drive = max(0, t - parked)
            let moving = t >= parked
            let speed = moving ? max(0, 18 + 14 * sin(drive / 7)) : 0
            let longG = moving ? (14.0 / 7.0) * cos(drive / 7) / 9.81 : 0
            let latG = moving ? sin(drive / 4) * 0.3 : 0
            return RaceBoxSample(
                latitude: 36.5844 + sin(drive / 30) * 0.002,
                longitude: -121.7536 + cos(drive / 30) * 0.002,
                altitudeMeters: 30 + sin(drive / 11) * 4,
                speedMps: speed,
                headingDegrees: (drive * 6).truncatingRemainder(dividingBy: 360),
                // z = +1 g: a logger at rest reads one g "up" (specific force).
                gForce: RaceBoxVector3(x: latG, y: longG, z: 1.0),
                rotationRate: RaceBoxVector3(x: 0, y: 0, z: moving ? sin(drive / 4) * 20 : 0),
                satellites: 14, hasFix: true)
        }
        simulated = source
        deviceInfo = RaceBoxDeviceInfo(model: .micro, serialNumber: "0000000001",
                                       firmware: RaceBoxFirmware("3.3"),
                                       hardwareRevision: "1.0", manufacturer: "RaceBox")
        Task { [weak self] in
            guard let self else { return }
            await self.attach(session: RaceBoxSession(transport: source))
            source.start()
            self.state = .connected
            self.publishesToBus = self.useForRecording
            self.prepareFrameForSession()
            await self.refreshRecordingStatus()
        }
    }

    /// Replayed drive: present as a connected Micro and accept frames from
    /// the replay feed so the links widget and motion ownership match the car.
    func startReplay() {
        disconnect()
        deviceInfo = RaceBoxDeviceInfo(model: .micro, serialNumber: "replay",
                                       firmware: RaceBoxFirmware("3.3"),
                                       hardwareRevision: "1.0", manufacturer: "RaceBox")
        state = .connected
        publishesToBus = true
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                if let last = self.lastMessageAt, self.state == .connected {
                    self.dataStalled = monotonicSeconds() - last > Self.stallAfter
                }
            }
        }
    }

    func ingestReplay(_ message: RaceBoxDataMessage) {
        latest = message
        lastMessageAt = monotonicSeconds()
        dataStalled = false
    }
    #endif

    private static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func describe(_ error: Error) -> String {
        switch error {
        case BleTransportError.connectionFailed(let reason): return reason
        case BleTransportError.peripheralNotFound: return "device not found"
        case BleTransportError.bluetoothUnauthorized: return "Bluetooth permission denied"
        case BleTransportError.bluetoothUnavailable: return "Bluetooth unavailable"
        case BleTransportError.noSerialCharacteristics: return "not a RaceBox (no UART service)"
        case RaceBoxError.timeout: return "device did not reply"
        case RaceBoxError.rejected: return "device rejected the command"
        case RaceBoxError.transportClosed: return "link closed"
        default: return "\(error)"
        }
    }
}
