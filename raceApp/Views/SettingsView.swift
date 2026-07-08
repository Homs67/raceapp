//
//  SettingsView.swift
//  raceApp
//
//  Settings + connection: adapter status/setup, units, shift indicator,
//  diagnostics, demo, privacy (connection flow per 06-connection-flow.md).
//

import SwiftUI
import ObdKit
import SessionKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage("keepScreenAwake") private var keepAwake = false
    @AppStorage("shiftEnabled") private var shiftEnabled = false
    @AppStorage("shiftRPM") private var shiftRPM: Double = 5500
    @State private var showAllDevices = false

    private var connection: ConnectionController { model.connection }

    var body: some View {
        NavigationStack {
            List {
                adapterSection
                if !connection.carLinkUp && !connection.isScanning {
                    setupSection
                    warningSection
                    recoverySection
                }
                settingsSection
                shiftSection
                diagnosticsSection
                demoSection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgScreen)
            .navigationTitle("Settings")
        }
    }

    // MARK: - Shift indicator

    private var shiftSection: some View {
        Section {
            Toggle("Performance shift indicator", isOn: $shiftEnabled)
                .font(.system(size: 14))
            if shiftEnabled {
                HStack(spacing: 8) {
                    ForEach(ShiftIndicator.presets, id: \.name) { preset in
                        Button {
                            shiftRPM = preset.rpm
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(abs(shiftRPM - preset.rpm) < 1 ? Color.black : Color.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(abs(shiftRPM - preset.rpm) < 1 ? Color.accent : Color.white.opacity(0.08),
                                           in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Shift at")
                            .font(.system(size: 14))
                        Spacer()
                        Text("\(Int(shiftRPM)) rpm")
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.accent)
                    }
                    Slider(value: $shiftRPM, in: 2000...7400, step: 100)
                        .tint(Color.accent)
                }
            }
        } header: {
            Text("Shift Indicator")
        } footer: {
            Text("Lights fill as you approach your shift RPM and flash when it's time to shift. MX-5 ND2 (7,500 redline): Street 5,500 · Track 7,200.")
        }
        .listRowBackground(Color.cardGray)
    }

    // MARK: - Adapter status / scan

    @ViewBuilder
    private var adapterSection: some View {
        Section {
            switch connection.state {
            case .live, .waitingForIgnition, .connectingEcu:
                connectedCard
            case .scanning:
                scanningList
            case .needsPermission:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bluetooth permission needed")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Allow Bluetooth access so the app can talk to your adapter.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .connecting, .discoveringGatt, .initializingElm, .reconnecting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(connection.stateDescription)
                        .font(.system(size: 13))
                    Spacer()
                    Button("Cancel") { connection.forget() }
                        .font(.system(size: 12))
                }
            case .idle:
                VStack(alignment: .leading, spacing: 10) {
                    if let error = connection.lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.warnAmber)
                    }
                    Button {
                        connection.startScan(showAll: showAllDevices)
                    } label: {
                        Text("Scan for adapters")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Adapter")
        }
        .listRowBackground(Color.cardBg)
    }

    private var connectedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(connection.carLinkUp ? Color.okGreen : Color.warnAmber)
                    .frame(width: 8, height: 8)
                Text(connection.isDemo ? "Demo adapter" : (connection.storedAdapterName ?? "Adapter"))
                    .font(.system(size: 14, weight: .semibold))
                if connection.carLinkUp {
                    Text("· \(String(format: "%.0f", model.bus.obdHz(now: uptimeNow()))) Hz")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(statusDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(connection.isDemo ? "Stop demo" : "Forget adapter", role: .destructive) {
                connection.forget()
            }
            .font(.system(size: 13))
        }
        .padding(.vertical, 4)
    }

    private var statusDetail: String {
        if connection.state == .waitingForIgnition {
            return "Waiting for ignition — parked with the key off? This is normal, not an error. Turn the key and data starts by itself."
        }
        var parts: [String] = []
        if let car = connection.carInfo, let make = car.make {
            parts.append("\(make) \(car.model ?? "")".trimmingCharacters(in: .whitespaces))
        }
        if connection.supportedPidCount > 0 {
            parts.append("\(connection.supportedPidCount) PIDs")
        }
        parts.append("auto-reconnects every drive")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var scanningList: some View {
        HStack {
            ProgressView()
            Text("Scanning… plug in the adapter, ignition on")
                .font(.system(size: 13))
            Spacer()
            Button("Stop") { connection.stopScan() }
                .font(.system(size: 12))
        }
        ForEach(connection.discovered) { adapter in
            Button {
                connection.select(adapter)
            } label: {
                HStack {
                    Text(adapter.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text("\(adapter.rssi) dBm")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        Toggle("Don't see your adapter? Show all devices", isOn: $showAllDevices)
            .font(.system(size: 12))
            .onChange(of: showAllDevices) {
                connection.startScan(showAll: showAllDevices)
            }
    }

    // MARK: - Setup guidance

    private var setupSection: some View {
        Section("First-time setup") {
            VStack(alignment: .leading, spacing: 10) {
                setupStep(1, "Plug the adapter into the OBD2 port — usually under the dash, driver's side. Look for its light.")
                setupStep(2, "Turn the ignition on (engine can stay off).")
                setupStep(3, "Tap Scan for adapters above.")
                setupStep(4, "Pick VEEPEAK from the list.")
                setupStep(5, "Done — the app reconnects by itself every drive.")
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.cardBg)
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
                .foregroundStyle(Color.accentCyan)
                .frame(width: 18, height: 18)
                .background(Color.accentCyan.opacity(0.12), in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.75))
        }
    }

    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.warnAmber)
                Text("**Don't pair in Bluetooth Settings.** The adapter accepts one connection at a time — pairing there blocks the app from finding it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .listRowBackground(Color.warnAmber.opacity(0.07))
    }

    private var recoverySection: some View {
        Section("Not finding it?") {
            VStack(alignment: .leading, spacing: 8) {
                bullet("Is the adapter's light on? Check that it's seated firmly in the port.")
                bullet("Is the ignition on?")
                bullet("Force-quit other OBD apps (Car Scanner, RaceChrono) — the adapter allows one connection.")
                bullet("Paired it in Bluetooth Settings by mistake? Unplug the adapter, wait 10 seconds, plug it back in.")
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.cardBg)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").foregroundStyle(Color.muted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section("Settings") {
            Picker("Units", selection: $metric) {
                Text("Imperial").tag(false)
                Text("Metric").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("Keep screen awake while recording", isOn: $keepAwake)
                .font(.system(size: 13))
                .onChange(of: keepAwake) {
                    model.recording.applyIdleTimerPolicy()
                }
            LabeledContent("Sessions on device") {
                Text(ByteCountFormatter.string(fromByteCount: model.store.totalStorageBytes(), countStyle: .file))
            }
            .font(.system(size: 13))
        }
        .listRowBackground(Color.cardBg)
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Adapter diagnostics", systemImage: "stethoscope")
                    .font(.system(size: 14))
            }
        } footer: {
            Text("See exactly what this car's ECU supports, the real data rate, and share a report.")
        }
        .listRowBackground(Color.cardGray)
    }

    private var demoSection: some View {
        Section {
            Button {
                connection.isDemo ? connection.stopDemo() : connection.startDemo()
            } label: {
                Text(connection.isDemo ? "Stop demo" : "Try with demo data")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentCyan)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentCyan.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        } footer: {
            Text("No adapter yet? Demo mode runs the whole app on a simulated MX-5 canyon drive.")
        }
    }

    private var privacySection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Everything stays on your phone. No account, no cloud — nothing leaves the device except the files you export yourself.")
                .font(.system(size: 11.5))
        }
    }
}
