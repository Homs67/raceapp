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

    init() {
        transport = CoreBluetoothTransport(profile: .raceBox)
    }

    var statusText: String {
        switch state {
        case .idle: return storedDeviceName.map { "Not connected — \($0)" } ?? "Not connected"
        case .scanning: return "Scanning for RaceBox…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected: return deviceInfo?.displayName ?? "Connected"
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
            }
        }
    }

    private func ingest(_ message: RaceBoxDataMessage) {
        latest = message
        recentMessages.append(message)
        if recentMessages.count > 200 { recentMessages.removeFirst(100) }
        appendLog(message)
        publish(message)
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
            let speed = max(0, 18 + 14 * sin(t / 7))
            return RaceBoxSample(
                latitude: 36.5844 + sin(t / 30) * 0.002,
                longitude: -121.7536 + cos(t / 30) * 0.002,
                altitudeMeters: 30 + sin(t / 11) * 4,
                speedMps: speed,
                headingDegrees: (t * 6).truncatingRemainder(dividingBy: 360),
                gForce: RaceBoxVector3(x: cos(t / 5) * 0.35, y: sin(t / 4) * 0.6, z: 1.0),
                rotationRate: RaceBoxVector3(x: sin(t / 6) * 3, y: cos(t / 8) * 2, z: sin(t / 4) * 20),
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
            await self.refreshRecordingStatus()
        }
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
