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

    func startDemo() {
        teardownConnection()
        isDemo = true
        state = .connecting
        let feed = DemoTelemetryFeed(bus: bus)
        demoFeed = feed
        feed.start()
        connectionTask = Task { [weak self] in
            await self?.handshake(transport: SimulatedAdapterTransport(), elmProtocol: nil)
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

            var supported: SupportedPids?
            while supported == nil, !Task.isCancelled {
                do {
                    supported = try await session.connectEcu()
                } catch let error as ElmError
                    where error == .unableToConnect || error == .noData || error == .timeout || error == .stopped {
                    state = .waitingForIgnition
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            guard let supported else { return }
            supportedPidCount = supported.pids.count
            self.supportedPids = supported

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
        guard let session, let supported = supportedPids else { return }
        pollerTask?.cancel()
        let poller = PidPoller(session: session)
        self.poller = poller
        pollerTask = Task { [bus] in
            await poller.apply(supportedPids: supported)
            for await sample in await poller.samples() {
                bus.publish(.obd(sample.channel), sample.value, at: sample.timestamp)
            }
        }
    }

    // MARK: - Diagnostics (driveway spike report, 03 §6)

    var canRunDiagnostics: Bool { session != nil }

    /// Full ECU sweep → a shareable plain-text report. Pauses live polling for
    /// clean timing, then resumes. Works against the demo adapter too.
    func runDiagnostics() async -> String {
        guard let session else {
            return "Not connected. Connect the adapter (or start demo) in Connection, then run diagnostics."
        }
        pollerTask?.cancel()
        pollerTask = nil
        await poller?.stop()

        var lines: [String] = []
        func log(_ text: String = "") { lines.append(text) }

        log("RACEAPP · OBD-II DIAGNOSTICS")
        log("Adapter: \(isDemo ? "DEMO (simulated — not a real car)" : (storedAdapterName ?? "unknown"))")
        if let vin = try? await session.readVin() { log("VIN: \(vin)") }
        if let ati = try? await session.execute("ATI") { log("ELM: \(ati.joined(separator: " "))") }
        if let dpn = try? await session.execute("ATDPN") { log("Protocol (ATDPN): \(dpn.joined())") }

        if !isDemo {
            log()
            log("BLUETOOTH / GATT:")
            log(bleTransport?.gattTreeDescription ?? "(unavailable)")
        }

        let supported = (try? await session.connectEcu()) ?? SupportedPids(pids: [])
        log()
        log("CHANNELS (\(supported.pids.count) PIDs reported by ECU):")
        for channel in ObdChannel.allCases {
            let pidHex = String(format: "%02X", channel.pid)
            if supported.supports(channel) {
                let response = try? await session.execute(String(format: "01%02X1", channel.pid))
                let value = response.flatMap { PidDecoder.decodeMode01(lines: $0).first?.value }
                let valueText = value.map { String(format: "%.2f %@", $0, channel.unit) } ?? "supported, no value"
                log("  [\(pidHex)] \(channel.rawValue): \(valueText)")
            } else {
                log("  [\(pidHex)] \(channel.rawValue): not supported")
            }
        }

        let multi = try? await session.execute("010C0D111")
        let multiCount = multi.map { PidDecoder.decodeMode01(lines: $0).count } ?? 0
        log()
        log("Multi-PID request (010C0D11 → RPM+speed+throttle in one call): "
            + (multiCount >= 3 ? "SUPPORTED (\(multiCount) values / request)" : "NOT supported — sequential fallback"))

        let seqHz = await measureUpdateRate(session: session, commandsPerUpdate: ["010C1", "010D1", "01111"], rounds: 12)
        let multiHz = await measureUpdateRate(session: session, commandsPerUpdate: ["010C0D111"], rounds: 12)
        log(String(format: "Fast-loop update rate: sequential ~%.1f Hz, multi-PID ~%.1f Hz", seqHz, multiHz))

        if let dtc = try? await session.readDtcStatus() {
            log()
            log("Check engine: MIL \(dtc.milOn ? "ON" : "OFF"), \(dtc.dtcCount) stored code(s)")
        }

        beginPolling() // resume live gauges
        return lines.joined(separator: "\n")
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
