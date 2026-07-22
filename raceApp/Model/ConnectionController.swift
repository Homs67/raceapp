//
//  ConnectionController.swift
//  raceApp
//
//  Drives the connection lifecycle (06-connection-flow.md): scan → connect →
//  ELM init → ECU (⇄ waiting-for-ignition) → live polling, plus silent
//  reconnect, adapter persistence, and demo mode.
//

import Foundation
import SwiftUI
import ObdKit
import SessionKit

@MainActor @Observable
final class ConnectionController {

    private enum Keys {
        static let adapterId = "adapter.uuid"
        static let adapterName = "adapter.name"
        static let elmProtocol = "adapter.elmProtocol"
        static let carVin = "car.vin"
    }

    private(set) var state: ObdConnectionState = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var isScanning = false
    private(set) var scanTimedOut = false
    private(set) var showAllDevices = false
    private(set) var bluetoothRadio: BluetoothRadioState = .unknown
    private(set) var carInfo: SessionManifest.CarInfo?
    private(set) var supportedPidCount = 0
    private(set) var milOn: Bool?
    private(set) var dtcCount: Int?
    private(set) var lastError: String?
    private(set) var isDemo = false
    /// Debug override so Settings can preview every OBD step without hardware.
    var uiStatusOverride: OBDAdapterUIStatus?
    /// The track the current session is on, when known (demo, or later auto-matched).
    private(set) var activeTrack: Track?
    /// Recorder hook — set by AppModel so link drops mark gaps (R1.8).
    var onObdLinkLost: (@MainActor () -> Void)?

    private let bus: TelemetryBus
    /// One CoreBluetooth central for the app lifetime. Creating a new manager
    /// per scan/connect with the same restore ID was breaking reconnects.
    private let bleTransport = CoreBluetoothTransport()
    private var session: Elm327Session?
    private var poller: PidPoller?
    private var supportedPids: SupportedPids?
    private var scanTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var walkthroughTask: Task<Void, Never>?
    private var demoFeed: DemoTelemetryFeed?
    private var reconnectingAfterLinkLoss = false
    /// Prevents repeated auto-select while RSSI updates keep arriving.
    private var didAutoSelectThisScan = false

    init(bus: TelemetryBus) {
        self.bus = bus
        bleTransport.onRadioStateChange = { [weak self] radio in
            Task { @MainActor in
                guard let self else { return }
                self.bluetoothRadio = radio
                if radio == .poweredOn {
                    self.beginAdapterDiscoveryIfNeeded()
                }
            }
        }
        bluetoothRadio = bleTransport.radioState
    }

    // MARK: - Derived UI state

    var adapterLinkUp: Bool {
        if let uiStatusOverride {
            if case .connected = uiStatusOverride { return true }
            return false
        }
        switch state {
        case .waitingForIgnition, .live: return true
        case .connectingEcu: return true
        default: return false
        }
    }
    var carLinkUp: Bool { state == .live }

    var storedAdapterName: String? { UserDefaults.standard.string(forKey: Keys.adapterName) }
    var hasStoredAdapter: Bool { UserDefaults.standard.string(forKey: Keys.adapterId) != nil }

    private var storedAdapterId: UUID? {
        UserDefaults.standard.string(forKey: Keys.adapterId).flatMap(UUID.init(uuidString:))
    }

    var adapterDisplayName: String {
        if isDemo { return "Demo adapter" }
        return storedAdapterName ?? "Adapter"
    }

    /// Settings card step derived from BLE + connection + scan results.
    var adapterUIStatus: OBDAdapterUIStatus {
        if let uiStatusOverride { return uiStatusOverride }

        if isDemo {
            switch state {
            case .live:
                return .connected(adapterDisplayName, waitingForIgnition: false)
            case .waitingForIgnition:
                return .connected(adapterDisplayName, waitingForIgnition: true)
            case .connecting, .discoveringGatt, .initializingElm, .connectingEcu, .reconnecting:
                return .connecting(adapterDisplayName)
            default:
                break
            }
        }

        switch bluetoothRadio {
        case .poweredOff, .unsupported, .unauthorized:
            return .bluetoothOff
        case .unknown, .poweredOn:
            break
        }

        switch state {
        case .needsPermission:
            return .bluetoothOff
        case .live:
            return .connected(adapterDisplayName, waitingForIgnition: false)
        case .waitingForIgnition:
            return .connected(adapterDisplayName, waitingForIgnition: true)
        case .connecting, .discoveringGatt, .initializingElm, .connectingEcu:
            return .connecting(adapterDisplayName)
        case .reconnecting:
            return .reconnecting(adapterDisplayName)
        case .scanning, .idle:
            if !discovered.isEmpty {
                return .found(discovered)
            }
            if scanTimedOut { return .notFound }
            return .finding
        }
    }

    var stateDescription: String {
        switch state {
        case .idle: return "Not connected"
        case .needsPermission: return "Bluetooth permission needed"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .discoveringGatt: return "Connecting…"
        case .initializingElm: return "Talking to adapter…"
        case .connectingEcu: return "Talking to car…"
        case .waitingForIgnition: return "Adapter link OK — waiting for ignition…"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting…"
        }
    }

    // MARK: - Launch / auto-reconnect (R6.1)

    /// Scan first — never hang on a remembered UUID that isn't advertising.
    /// Auto-connect only happens once the adapter is actually discovered.
    func onLaunch() {
        beginAdapterDiscoveryIfNeeded()
    }

    func onForeground() {
        beginAdapterDiscoveryIfNeeded()
    }

    // MARK: - Scanning

    /// Auto-scan when Bluetooth is ready and we aren't already linked / linking.
    func beginAdapterDiscoveryIfNeeded() {
        guard uiStatusOverride == nil else { return }
        guard !isDemo else { return }
        switch state {
        case .connecting, .discoveringGatt, .initializingElm, .connectingEcu,
             .waitingForIgnition, .live, .reconnecting:
            return
        case .scanning:
            return
        case .idle, .needsPermission:
            break
        }
        switch bluetoothRadio {
        case .poweredOff, .unauthorized, .unsupported:
            return
        case .unknown, .poweredOn:
            startScan(showAll: showAllDevices)
        }
    }

    /// User-facing retry after a timed-out / empty scan.
    func retryScan() {
        startScan(showAll: showAllDevices)
    }

    /// Cancel an in-flight connect/reconnect without forgetting the saved adapter.
    func cancelPendingConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        reconnectingAfterLinkLoss = false
        teardownSession(keepBluetooth: true)
        state = .idle
        startScan(showAll: showAllDevices)
    }

    func startScan(showAll: Bool = false) {
        stopScan()
        connectionTask?.cancel()
        connectionTask = nil
        reconnectingAfterLinkLoss = false
        teardownSession(keepBluetooth: true)
        showAllDevices = showAll
        isScanning = true
        scanTimedOut = false
        didAutoSelectThisScan = false
        discovered = []
        state = .scanning
        let transport = bleTransport
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled else { return }
            // Still searching with nothing heard → stop and show not-found + Retry.
            if self.state == .scanning, self.discovered.isEmpty {
                self.finishEmptyScan()
            }
        }
        scanTask = Task { [weak self] in
            do {
                let stream = try await transport.scan(
                    nameFilter: showAll ? nil : CoreBluetoothTransport.advertisedName)
                for await adapter in stream {
                    guard let self else { return }
                    self.handleDiscovery(adapter)
                }
            } catch BleTransportError.bluetoothUnauthorized {
                self?.state = .needsPermission
                self?.bluetoothRadio = .unauthorized
            } catch {
                self?.lastError = "Bluetooth unavailable"
                self?.state = .idle
                if self?.bluetoothRadio == .poweredOn {
                    self?.bluetoothRadio = .poweredOff
                }
            }
            self?.isScanning = false
        }
    }

    /// End an empty scan so UI can show not-found (keeps `scanTimedOut`).
    private func finishEmptyScan() {
        scanTimedOut = true
        scanTask?.cancel()
        scanTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        bleTransport.stopScan()
        isScanning = false
        if state == .scanning { state = .idle }
    }

    func setShowAllDevices(_ showAll: Bool) {
        // Always restart so Collapse returns to the filtered OBD scan.
        startScan(showAll: showAll)
    }

    private func handleDiscovery(_ adapter: DiscoveredAdapter) {
        scanTimedOut = false
        if let index = discovered.firstIndex(where: { $0.id == adapter.id }) {
            discovered[index] = adapter
        } else {
            discovered.append(adapter)
        }
        discovered.sort { $0.rssi > $1.rssi }

        // Already connecting / live — ignore further discoveries.
        switch state {
        case .connecting, .discoveringGatt, .initializingElm, .connectingEcu,
             .waitingForIgnition, .live, .reconnecting:
            return
        default:
            break
        }

        // Last-used adapter → always reconnect immediately.
        if let stored = storedAdapterId, adapter.id == stored {
            didAutoSelectThisScan = true
            select(adapter)
            return
        }

        // Filtered OBD scan (VEEPEAK): auto-connect the sole hit so first-time
        // pairing doesn't depend on a nested List button.
        if !showAllDevices, !didAutoSelectThisScan, discovered.count == 1 {
            didAutoSelectThisScan = true
            select(adapter)
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        bleTransport.stopScan()
        isScanning = false
        if state == .scanning { state = .idle }
    }

    func select(_ adapter: DiscoveredAdapter) {
        stopScan()
        UserDefaults.standard.set(adapter.id.uuidString, forKey: Keys.adapterId)
        UserDefaults.standard.set(adapter.name, forKey: Keys.adapterName)
        connect(to: adapter.id)
    }

    func forget() {
        walkthroughTask?.cancel()
        walkthroughTask = nil
        uiStatusOverride = nil
        teardownSession(keepBluetooth: true)
        for key in [Keys.adapterId, Keys.adapterName, Keys.elmProtocol, Keys.carVin] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        carInfo = nil
        isDemo = false
        discovered = []
        scanTimedOut = false
        state = .idle
    }

    // MARK: - Debug UI status preview

    func clearUIStatusOverride() {
        walkthroughTask?.cancel()
        walkthroughTask = nil
        uiStatusOverride = nil
    }

    /// Walk through every Settings OBD step (~2s each) for UI testing without hardware.
    func playAdapterStatusWalkthrough() {
        walkthroughTask?.cancel()
        walkthroughTask = Task { [weak self] in
            for step in OBDAdapterUIStatus.previewCatalog {
                guard let self, !Task.isCancelled else { return }
                self.uiStatusOverride = step
                try? await Task.sleep(for: .seconds(2.2))
            }
            self?.uiStatusOverride = nil
        }
    }

    // MARK: - Demo mode (R5.4)

    func startDemo(track: Track? = nil) {
        teardownSession(keepBluetooth: true)
        isDemo = true
        state = .connecting
        // One simulator on a shared clock drives both the phone feed and the OBD
        // adapter, so GPS speed and OBD speed agree. Defaults to Laguna Seca.
        let selected = track ?? TrackDatabase.track(id: "laguna-seca")
        activeTrack = selected
        let trackDrive = selected.map { TrackDemoDrive(track: $0) }
        let feed = DemoTelemetryFeed(bus: bus, trackDrive: trackDrive)
        demoFeed = feed
        feed.start()
        let transport = SimulatedAdapterTransport()
        if let td = trackDrive {
            transport.setDriveSource { td.obdSample() }
        }
        connectionTask = Task { [weak self] in
            await self?.handshake(transport: transport, elmProtocol: nil)
        }
    }

    func stopDemo() {
        guard isDemo else { return }
        forget()
    }

    // MARK: - Connect + handshake

    private func connect(to id: UUID) {
        stopScan()
        teardownSession(keepBluetooth: true)
        isDemo = false
        let transport = bleTransport
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleLinkLost(adapterId: id) }
        }
        transport.onRestore = { [weak self] restoredId in
            Task { @MainActor in
                self?.handleRestoredPeripheral(restoredId)
            }
        }
        state = .connecting
        reconnectingAfterLinkLoss = false
        connectionTask = Task { [weak self] in
            await self?.connectLoop(transport: transport, id: id, startAttempt: 0)
        }
    }

    private func connectLoop(transport: CoreBluetoothTransport, id: UUID, startAttempt: Int) async {
        var attempt = startAttempt
        while !Task.isCancelled {
            do {
                try await transport.connect(to: id) // BLE + GATT + notify inside
                let storedProtocol = UserDefaults.standard.object(forKey: Keys.elmProtocol) as? Int
                await handshake(transport: transport, elmProtocol: storedProtocol)
                return
            } catch {
                attempt += 1
                state = .reconnecting(attempt: attempt)
                lastError = (error as? BleTransportError).map(Self.describe)
                try? await Task.sleep(for: ObdConnectionReducer.reconnectDelay(attempt: attempt))
            }
        }
    }

    private func handshake(transport: any ObdTransport, elmProtocol: Int?) async {
        let session = Elm327Session(transport: transport)
        self.session = session
        do {
            state = .initializingElm
            _ = try await session.initialize(elmProtocol: elmProtocol)
            state = .connectingEcu

            // ECU readiness is decided by directly probing RPM, not by the 0100
            // supported-bitmap — some adapters/ECUs answer live PIDs fine but
            // return a bitmap we can't parse. Only genuine no-answer = ignition off.
            var ecuReady = false
            while !ecuReady, !Task.isCancelled {
                if await session.probeValue(pid: 0x0C) != nil {
                    ecuReady = true
                } else {
                    state = .waitingForIgnition
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            guard ecuReady else { return }

            // Capability bitmap is best-effort; polling does not depend on it.
            let bitmap = (try? await session.connectEcu()) ?? SupportedPids(pids: [])
            supportedPidCount = bitmap.pids.count
            supportedPids = bitmap.pids.isEmpty ? nil : bitmap

            if let vin = try? await session.readVin() {
                carInfo = Self.carInfo(fromVin: vin, adapterName: isDemo ? "Demo adapter" : storedAdapterName)
                UserDefaults.standard.set(vin, forKey: Keys.carVin)
            }
            if let status = try? await session.readDtcStatus() {
                milOn = status.milOn
                dtcCount = status.dtcCount
            }

            beginPolling()
            state = .live
            lastError = nil
        } catch {
            lastError = "Adapter didn't respond — unplug it for 10 seconds and plug it back in."
            state = .idle
        }
    }

    private func beginPolling() {
        guard let session else { return }
        pollerTask?.cancel()
        let poller = PidPoller(session: session)
        self.poller = poller
        let supported = supportedPids // nil → poll unfiltered; poller drops NO-DATA channels
        pollerTask = Task { [bus] in
            if let supported { await poller.apply(supportedPids: supported) }
            for await sample in await poller.samples() {
                bus.publish(.obd(sample.channel), sample.value, at: sample.timestamp)
            }
        }
    }

    // MARK: - Diagnostics (driveway spike report, 03 §6)

    var canRunDiagnostics: Bool { session != nil }

    /// Full ECU sweep → a structured report (shared as JSON + readable text).
    /// Pauses live polling for clean timing, then resumes. Works in demo too.
    func runDiagnostics() async -> DiagnosticsReport {
        let now = ISO8601DateFormatter().string(from: Date())
        guard let session else {
            return .unavailable(generatedAt: now, isDemo: isDemo)
        }
        pollerTask?.cancel()
        pollerTask = nil
        await poller?.stop()

        let vin = try? await session.readVin()
        let elm = (try? await session.execute("ATI"))?.joined(separator: " ")
        let proto = (try? await session.execute("ATDPN"))?.joined()
        let gatt = isDemo ? nil : bleTransport.gattTreeDescription

        // Probe every channel directly — the real test of availability, rather
        // than trusting the 0100 bitmap (which some adapters mis-report).
        let bitmap = (try? await session.connectEcu()) ?? SupportedPids(pids: [])
        var channels: [DiagnosticsReport.Channel] = []
        var probedCount = 0
        for channel in ObdChannel.allCases {
            let pidHex = String(format: "%02X", channel.pid)
            let value = await session.probeValue(pid: channel.pid)
            if value != nil { probedCount += 1 }
            channels.append(.init(name: channel.rawValue, pid: pidHex,
                                  supported: value != nil, value: value, unit: channel.unit))
        }
        let supportedCount = max(bitmap.pids.count, probedCount)

        let multi = try? await session.execute("010C0D111")
        let multiCount = multi.map { PidDecoder.decodeMode01(lines: $0).count } ?? 0
        let seqHz = await measureUpdateRate(session: session, commandsPerUpdate: ["010C1", "010D1", "01111"], rounds: 12)
        let multiHz = await measureUpdateRate(session: session, commandsPerUpdate: ["010C0D111"], rounds: 12)
        let dtc = try? await session.readDtcStatus()

        beginPolling() // resume live gauges

        return DiagnosticsReport(
            appVersion: DiagnosticsReport.appVersionString,
            generatedAt: now,
            isDemo: isDemo,
            adapter: isDemo ? "Demo adapter" : storedAdapterName,
            elm: elm,
            obdProtocol: proto,
            vin: vin,
            gatt: gatt,
            supportedPidCount: supportedCount,
            multiPidSupported: multiCount >= 3,
            sequentialHz: seqHz,
            multiPidHz: multiHz,
            milOn: dtc?.milOn,
            dtcCount: dtc?.dtcCount,
            channels: channels
        )
    }

    /// Supported PIDs captured at connect, for embedding in session exports.
    var supportedPidList: [Int] {
        (supportedPids?.pids.map { Int($0) } ?? []).sorted()
    }

    /// Time `rounds` full fast-loop updates and return updates-per-second.
    private func measureUpdateRate(session: Elm327Session, commandsPerUpdate: [String], rounds: Int) async -> Double {
        let start = monotonicNow()
        for _ in 0..<rounds {
            for command in commandsPerUpdate { _ = try? await session.execute(command) }
        }
        let elapsed = monotonicNow() - start
        return elapsed > 0 ? Double(rounds) / elapsed : 0
    }

    private func handleLinkLost(adapterId: UUID) {
        guard !isDemo else { return }
        // connectLoop already retries mid-connect failures; only unexpected
        // drops after a live link should spawn a fresh reconnect task.
        if case .reconnecting = state { return }
        if reconnectingAfterLinkLoss { return }
        pollerTask?.cancel()
        pollerTask = nil
        bus.clearObdChannels()
        onObdLinkLost?()
        guard state != .idle else { return } // user chose to disconnect
        reconnectingAfterLinkLoss = true
        state = .reconnecting(attempt: 1)
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectingAfterLinkLoss = false }
            await self.connectLoop(transport: self.bleTransport, id: adapterId, startAttempt: 1)
        }
    }

    private func handleRestoredPeripheral(_ id: UUID) {
        guard !isDemo,
              UserDefaults.standard.string(forKey: Keys.adapterId) == id.uuidString,
              connectionTask == nil else { return }
        state = .reconnecting(attempt: 0)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.connectLoop(transport: self.bleTransport, id: id, startAttempt: 0)
        }
    }

    /// Tear down ELM/polling without destroying the shared CBCentralManager.
    private func teardownSession(keepBluetooth: Bool) {
        connectionTask?.cancel()
        pollerTask?.cancel()
        connectionTask = nil
        pollerTask = nil
        reconnectingAfterLinkLoss = false
        demoFeed?.stop()
        demoFeed = nil
        bleTransport.onDisconnect = nil
        bleTransport.onRestore = nil
        if keepBluetooth {
            bleTransport.disconnect()
        }
        session = nil
        poller = nil
        supportedPids = nil
        bus.clearObdChannels()
        supportedPidCount = 0
        milOn = nil
        dtcCount = nil
    }

    // MARK: - Helpers

    static func carInfo(fromVin vin: String, adapterName: String?) -> SessionManifest.CarInfo {
        // WMI prefix → make; model stays generic until the car library (M3)
        let make: String? = switch String(vin.prefix(3)) {
        case "JM1": "Mazda"
        case "JHM", "JH4": "Honda"
        case "JT2", "JTD": "Toyota"
        case "WP0": "Porsche"
        case "WBA", "WBS": "BMW"
        case "1G1": "Chevrolet"
        default: nil
        }
        let model: String? = vin.hasPrefix("JM1ND") ? "MX-5" : nil
        return .init(make: make, model: model, vin: vin, adapterName: adapterName)
    }

    private static func describe(_ error: BleTransportError) -> String {
        switch error {
        case .bluetoothUnavailable: return "Bluetooth is off"
        case .bluetoothUnauthorized: return "Bluetooth permission denied"
        case .peripheralNotFound: return "Adapter not found"
        case .connectionFailed(let reason): return reason
        case .noSerialCharacteristics: return "Unsupported adapter"
        }
    }
}
