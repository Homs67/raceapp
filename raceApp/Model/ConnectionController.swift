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
    private(set) var carInfo: SessionManifest.CarInfo?
    private(set) var supportedPidCount = 0
    private(set) var milOn: Bool?
    private(set) var dtcCount: Int?
    private(set) var lastError: String?
    private(set) var isDemo = false
    /// Recorder hook — set by AppModel so link drops mark gaps (R1.8).
    var onObdLinkLost: (@MainActor () -> Void)?

    private let bus: TelemetryBus
    private var bleTransport: CoreBluetoothTransport?
    private var session: Elm327Session?
    private var poller: PidPoller?
    private var supportedPids: SupportedPids?
    private var scanTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var demoFeed: DemoTelemetryFeed?

    init(bus: TelemetryBus) {
        self.bus = bus
    }

    // MARK: - Derived UI state

    var adapterLinkUp: Bool {
        switch state {
        case .connectingEcu, .waitingForIgnition, .live: return true
        default: return false
        }
    }
    var carLinkUp: Bool { state == .live }

    var storedAdapterName: String? { UserDefaults.standard.string(forKey: Keys.adapterName) }
    var hasStoredAdapter: Bool { UserDefaults.standard.string(forKey: Keys.adapterId) != nil }

    var stateDescription: String {
        switch state {
        case .idle: return "Not connected"
        case .needsPermission: return "Bluetooth permission needed"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .discoveringGatt: return "Connecting…"
        case .initializingElm: return "Talking to adapter…"
        case .connectingEcu: return "Talking to car…"
        case .waitingForIgnition: return "Waiting for ignition…"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting…"
        }
    }

    // MARK: - Launch / auto-reconnect (R6.1)

    func onLaunch() {
        guard let idString = UserDefaults.standard.string(forKey: Keys.adapterId),
              let id = UUID(uuidString: idString) else { return }
        connect(to: id)
    }

    // MARK: - Scanning

    func startScan(showAll: Bool = false) {
        stopScan()
        teardownConnection()
        isScanning = true
        discovered = []
        state = .scanning
        let transport = CoreBluetoothTransport()
        bleTransport = transport
        scanTask = Task { [weak self] in
            do {
                let stream = try await transport.scan(
                    nameFilter: showAll ? nil : CoreBluetoothTransport.advertisedName)
                for await adapter in stream {
                    guard let self else { return }
                    if let index = self.discovered.firstIndex(where: { $0.id == adapter.id }) {
                        self.discovered[index] = adapter
                    } else {
                        self.discovered.append(adapter)
                    }
                    self.discovered.sort { $0.rssi > $1.rssi }
                }
            } catch BleTransportError.bluetoothUnauthorized {
                self?.state = .needsPermission
            } catch {
                self?.lastError = "Bluetooth unavailable"
                self?.state = .idle
            }
            self?.isScanning = false
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
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
        teardownConnection()
        for key in [Keys.adapterId, Keys.adapterName, Keys.elmProtocol, Keys.carVin] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        carInfo = nil
        isDemo = false
        state = .idle
    }

    // MARK: - Demo mode (R5.4)

    func startDemo(track: Track? = nil) {
        teardownConnection()
        isDemo = true
        state = .connecting
        // One simulator on a shared clock drives both the phone feed and the OBD
        // adapter, so GPS speed and OBD speed agree. Defaults to Laguna Seca.
        let selected = track ?? TrackDatabase.track(id: "laguna-seca")
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
        teardownConnection()
        isDemo = false
        let transport = CoreBluetoothTransport()
        bleTransport = transport
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleLinkLost(adapterId: id) }
        }
        state = .connecting
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
        let gatt = isDemo ? nil : bleTransport?.gattTreeDescription

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
        pollerTask?.cancel()
        pollerTask = nil
        bus.clearObdChannels()
        onObdLinkLost?()
        guard state != .idle else { return } // user chose to disconnect
        state = .reconnecting(attempt: 1)
        guard let transport = bleTransport else { return }
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            await self?.connectLoop(transport: transport, id: adapterId, startAttempt: 1)
        }
    }

    private func teardownConnection() {
        connectionTask?.cancel()
        pollerTask?.cancel()
        connectionTask = nil
        pollerTask = nil
        demoFeed?.stop()
        demoFeed = nil
        bleTransport?.onDisconnect = nil
        bleTransport?.disconnect()
        bleTransport = nil
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
