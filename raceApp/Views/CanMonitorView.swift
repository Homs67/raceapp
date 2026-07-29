//
//  CanMonitorView.swift
//  raceApp
//
//  Beta CAN-bus monitor: takes over the adapter on its own connection, puts the
//  ELM327 into raw monitor mode, and reads broadcast signals OBD-II can't give
//  (steering, brake, accelerator). Read-only. Currently maps the Mazda MX-5 ND.
//

import SwiftUI
import ObdKit

struct CanMonitorView: View {
    @Environment(AppModel.self) private var model

    // Borrowed from ConnectionController — the app's ONE shared transport.
    // Never construct a CoreBluetoothTransport here: a second central with the
    // same restore identifier corrupts CoreBluetooth until app relaunch.
    @State private var transport: CoreBluetoothTransport?
    @State private var adapterId: UUID?
    @State private var session: CanMonitorSession?
    @State private var status = "Not connected"
    @State private var ready = false
    @State private var running = false
    @State private var report: CanMonitorReport?

    var body: some View {
        List {
            Section {
                Text("Connect with the engine running, then read. This uses a separate link, so the app's normal OBD connection is paused while you're here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muted)
            }
            .listRowBackground(Color.clear)

            Section {
                HStack {
                    Circle().fill(ready ? Color.accent : Color.mutedWeak).frame(width: 8, height: 8)
                    Text(status).font(.system(size: 14))
                    Spacer()
                    if !ready {
                        Button("Connect") { Task { await connect() } }
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            } header: { Text("Adapter") }
            .listRowBackground(Color.cardBg)
            .textCase(nil)

            if ready {
                Section {
                    actionButton("Read ND signals", system: "gauge.with.dots.needle.bottom.50percent") {
                        await run { await $0.monitor(signals: CanSignalMap.mazdaND, perID: .seconds(2)) }
                    }
                    actionButton("Scan bus — list all IDs", system: "dot.radiowaves.left.and.right") {
                        await run { await $0.scanBus(duration: .seconds(6)) }
                    }
                    actionButton("Discovery capture (~3 min)", system: "sparkle.magnifyingglass") {
                        await run { await $0.discover() }
                    }
                } footer: {
                    Text("Discovery alternates raw CAN capture with OBD readings, then auto-matches frame bytes to known channels. Best during warmup — start with a cold engine, keep it running, and blip the throttle now and then.")
                }
                .listRowBackground(Color.cardBg)
            }

            if let report {
                if !report.signals.isEmpty { signalsSection(report) }
                if !report.analysis.isEmpty { analysisSection(report) }
                framesSection(report)
                if !report.rawLines.isEmpty { rawSection(report) }
                if !report.rawLog.isEmpty { shareSection(report) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("CAN Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let borrowed = model.connection.borrowTransportForExternalTool()
            transport = borrowed.transport
            adapterId = borrowed.adapterId
            Task { await connect() } // auto-connect: reuses the live link if there is one
        }
        .onDisappear {
            // Keep the BLE link — the controller re-handshakes ELM over it.
            if let s = session {
                Task { await s.shutdown() }
            }
            model.connection.endExternalToolMode()
        }
    }

    // MARK: - Sections

    private func signalsSection(_ report: CanMonitorReport) -> some View {
        Section {
            ForEach(report.signals, id: \.key) { s in
                HStack {
                    Text(s.name).font(.system(size: 14))
                    Spacer()
                    if let v = s.value {
                        Text(String(format: "%.1f %@", v, s.unit))
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.accent)
                    } else {
                        Text(s.samples == 0 ? "no frames" : "no value")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.recordRed)
                    }
                }
            }
        } header: { Text("Decoded ND signals") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func analysisSection(_ report: CanMonitorReport) -> some View {
        Section {
            Text(report.analysis.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mutedStrong)
                .textSelection(.enabled)
        } header: { Text("Discovery analysis") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func framesSection(_ report: CanMonitorReport) -> some View {
        Section {
            if report.frames.isEmpty {
                Text("No frames received — the adapter may not pass raw CAN (try OBDLink MX+), or the engine is off.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recordRed)
            }
            ForEach(report.frames, id: \.id) { f in
                HStack {
                    Text(String(format: "0x%03X", f.id))
                        .font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Text("\(f.count) frames · \(String(format: "%.0f", f.hz)) Hz")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Color.mutedStrong)
                }
            }
        } header: { Text("Frames seen") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func rawSection(_ report: CanMonitorReport) -> some View {
        Section {
            Text(report.rawLines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mutedStrong)
                .textSelection(.enabled)
        } header: { Text("Raw sample") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func shareSection(_ report: CanMonitorReport) -> some View {
        Section {
            if let url = writeReport(report) {
                ShareLink(item: url) {
                    Label("Share CAN log", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
            }
        } footer: {
            Text("Full timestamped frame capture — share it for offline analysis or to add support for more signals.")
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func writeReport(_ report: CanMonitorReport) -> URL? {
        let header = "Mazda MX-5 ND · \(Date().formatted(date: .abbreviated, time: .standard))"
        let text = report.textReport(header: header)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raceapp-can-log.txt")
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func actionButton(_ title: String, system: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                if running { ProgressView().tint(.gray).scaleEffect(0.7) }
                Label(title, systemImage: system)
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .disabled(running)
    }

    // MARK: - Actions

    private func connect() async {
        guard let t = transport else { return }
        guard !ready else { return }
        status = "Connecting…"
        do {
            if t.isLinkReady {
                // App was already linked to the adapter — same pipe, no reconnect.
            } else if let id = adapterId {
                try await t.connect(to: id)
            } else {
                let stream = try await t.scan()
                var found: UUID?
                for await adapter in stream { found = adapter.id; break }
                t.stopScan()
                guard let found else { status = "No VEEPEAK found"; return }
                adapterId = found
                try await t.connect(to: found)
            }
            let s = CanMonitorSession(transport: t)
            await s.configure()
            session = s
            status = "Connected — ready"
            ready = true
        } catch {
            status = "Connect failed — \(shortError(error))"
        }
    }

    private func shortError(_ error: Error) -> String {
        if case BleTransportError.connectionFailed(let reason) = error { return reason }
        if case BleTransportError.peripheralNotFound = error { return "adapter not found" }
        return "Bluetooth unavailable"
    }

    private func run(_ body: @escaping (CanMonitorSession) async -> CanMonitorReport) async {
        guard let session else { return }
        running = true
        report = await body(session)
        running = false
    }
}
