//
//  SettingsView.swift
//  raceApp
//
//  Settings sheet: OBD adapter, preferences (car / shift / default dashboard),
//  and general units. Help + diagnostics live elsewhere.
//

import SwiftUI
import ObdKit
import SessionKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage("keepScreenAwake") private var keepAwake = false
    @AppStorage("shiftEnabled") private var shiftEnabled = false
    @AppStorage("shiftRPM") private var shiftRPM: Double = 5500
    @AppStorage("dashboardFace") private var dashboardFace = 0
    @State private var preferredCar = PreferredCar.load()
    @State private var showDashboardPicker = false

    private var connection: ConnectionController { model.connection }
    private let connectedGreen = Color(hex: 0x30D158)

    var body: some View {
        NavigationStack {
            List {
                ScreenPageTitle(title: "Settings")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                adapterSection
                preferencesSection
                generalSettingsSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "help":
                    OBDHelpView()
                case "my-car":
                    MyCarPickerView(selection: $preferredCar)
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $showDashboardPicker) {
                NavigationStack {
                    DefaultDashboardPicker(selection: $dashboardFace)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showDashboardPicker = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear { connection.beginAdapterDiscoveryIfNeeded() }
        }
    }

    // MARK: - OBD-II adapter

    @ViewBuilder
    private var adapterSection: some View {
        Section {
            adapterStatusCard
        } header: {
            HStack {
                Text(sectionTitle)
                Spacer()
                NavigationLink(value: "help") {
                    Text("Help")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentCyan)
                }
            }
            .textCase(nil)
        }
        .listRowBackground(Color.cardBg)
    }

    private var sectionTitle: String {
        if connection.showAllDevices { return "All devices" }
        if case .connected = connection.adapterUIStatus { return "OBD-II adapter" }
        return "OBD-II Device"
    }

    @ViewBuilder
    private var adapterStatusCard: some View {
        switch connection.adapterUIStatus {
        case .bluetoothOff:
            statusRow(
                icon: "bluetooth",
                text: "Turn on bluetooth to find a device",
                dimmed: true
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }

        case .finding:
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: nil,
                    text: connection.showAllDevices
                        ? "Scanning all Bluetooth devices…"
                        : "Finding an OBD-II adapter…",
                    dimmed: true,
                    progress: true
                )
                if connection.showAllDevices {
                    collapseAllDevicesButton
                }
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 10) {
                statusRow(
                    icon: nil,
                    text: connection.showAllDevices
                        ? "No Bluetooth devices found"
                        : "No OBD-II adapter found",
                    dimmed: true
                )
                retryScanButton
                if connection.showAllDevices {
                    collapseAllDevicesButton
                } else {
                    showAllDevicesButton
                }
            }

        case .found(let adapters):
            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    icon: nil,
                    text: connection.showAllDevices
                        ? "All Bluetooth devices"
                        : "Found an adapter…",
                    dimmed: true
                )
                ForEach(adapters) { adapter in
                    Button {
                        connection.select(adapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(adapter.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                Text("\(adapter.rssi) dBm")
                                    .font(.system(size: 11)).monospacedDigit()
                                    .foregroundStyle(Color.muted)
                            }
                            Spacer()
                            Text("Connect")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                if connection.showAllDevices {
                    collapseAllDevicesButton
                } else {
                    showAllDevicesButton
                }
            }

        case .connecting(let name):
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(name)…")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                Spacer()
                Button("Cancel") { connection.cancelPendingConnection() }
                    .font(.system(size: 13))
                    .buttonStyle(.borderless)
            }

        case .reconnecting(let name):
            HStack(spacing: 10) {
                ProgressView()
                Text("Reconnecting to \(name)…")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                Spacer()
                Button("Cancel") { connection.cancelPendingConnection() }
                    .font(.system(size: 13))
                    .buttonStyle(.borderless)
            }

        case .connected(let name, let waitingForIgnition):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(connectedGreen)
                    Text("Connected to \(name)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                if waitingForIgnition {
                    Text("Adapter link OK — turn ignition on for live car data")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                } else if connection.carLinkUp {
                    Text("\(String(format: "%.0f", model.bus.obdHz(now: uptimeNow()))) Hz")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                }
                Button(connection.isDemo ? "Stop demo" : "Disconnect") {
                    connection.forget()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.recordRed)
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
    }

    private var retryScanButton: some View {
        Button {
            connection.retryScan()
        } label: {
            Text("Retry")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .buttonStyle(.borderless)
    }

    private var showAllDevicesButton: some View {
        Button {
            connection.setShowAllDevices(true)
        } label: {
            HStack(spacing: 4) {
                Text("Show all devices")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.muted)
        }
        .buttonStyle(.plain)
    }

    private var collapseAllDevicesButton: some View {
        Button {
            connection.setShowAllDevices(false)
        } label: {
            Text("Collapse")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentCyan)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusRow(icon: String?, text: String, dimmed: Bool,
                           progress: Bool = false, action: (() -> Void)? = nil) -> some View {
        let row = HStack(spacing: 10) {
            if progress { ProgressView() }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(dimmed ? Color.muted : Color.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)

        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
            NavigationLink(value: "my-car") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("My car")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                    Text(preferredCar?.displayName ?? "Select from a list...")
                        .font(.system(size: 15))
                        .foregroundStyle(preferredCar == nil ? Color.mutedWeak : Color.textPrimary)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.cardGray)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Performance shift indicator", isOn: $shiftEnabled)
                    .font(.system(size: 14))
                if shiftEnabled {
                    Text("Shift at \(Int(shiftRPM)) RPM")
                        .font(.system(size: 14, weight: .medium))
                    Slider(value: $shiftRPM, in: 2000...7400, step: 100)
                        .tint(Color.accent)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.cardGray)

            VStack(alignment: .leading, spacing: 10) {
                Text("Default dashboard")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                DefaultDashboardPreview(face: dashboardFace)
                Button("Change") { showDashboardPicker = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentCyan)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.cardGray)
        }
        .textCase(nil)
    }

    // MARK: - General settings

    private var generalSettingsSection: some View {
        Section("Settings") {
            Picker("Imperial / Metric", selection: $metric) {
                Text("Imperial").tag(false)
                Text("Metric").tag(true)
            }
            .pickerStyle(.segmented)

            Toggle("Keep screen awake while recording", isOn: $keepAwake)
                .font(.system(size: 13))
                .onChange(of: keepAwake) {
                    model.applyRecordingIdlePolicy()
                }

            LabeledContent("Sessions on device") {
                Text(ByteCountFormatter.string(fromByteCount: model.store.totalStorageBytes(), countStyle: .file))
            }
            .font(.system(size: 13))
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }
}

// MARK: - OBD Help

struct OBDHelpView: View {
    var body: some View {
        List {
            Section("First-time setup") {
                VStack(alignment: .leading, spacing: 10) {
                    setupStep(1, "Plug the adapter into the OBD2 port — usually under the dash, driver's side. Look for its light.")
                    setupStep(2, "Turn on Bluetooth. Don't pair the adapter in iOS Bluetooth Settings — that blocks the app.")
                    setupStep(3, "Race App scans for an OBD-II adapter. When VEEPEAK appears, it connects (or tap Connect).")
                    setupStep(4, "If nothing shows up, tap Retry — or Show all devices if yours uses a different name.")
                    setupStep(5, "When you see “Connected” / “Adapter link OK”, the Bluetooth link works.")
                    setupStep(6, "Turn ignition on (engine can stay off) only when you want live car data.")
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.cardBg)

            Section("Connection vs live data") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("The app always finds the adapter first. It won't hang “Connecting…” to a remembered device that is powered off.")
                    bullet("Live car data needs the key on so the ECU answers. Until then the link can still be fine.")
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.cardBg)

            Section("Not finding it?") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Is the adapter's light on? Check that it's seated firmly in the port.")
                    bullet("Some cars only power the OBD port with ignition on — if there's no light, turn the key.")
                    bullet("Force-quit other OBD apps (Car Scanner, RaceChrono) — the adapter allows one connection.")
                    bullet("Paired it in Bluetooth Settings by mistake? Unplug the adapter, wait 10 seconds, plug it back in.")
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.cardBg)
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("OBD Help")
        .navigationBarTitleDisplayMode(.inline)
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").foregroundStyle(Color.muted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }
}

// MARK: - My car

private struct MyCarPickerView: View {
    @Binding var selection: PreferredCar?
    @State private var customMake = ""
    @State private var customModel = ""
    @State private var customYear = ""
    @State private var showCustom = false

    var body: some View {
        List {
            Section {
                ForEach(PreferredCar.presets) { car in
                    Button {
                        selection = car
                        car.save()
                    } label: {
                        HStack {
                            Text(car.displayName)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if selection?.id == car.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                }
                .listRowBackground(Color.cardGray)

                Button {
                    showCustom = true
                    if selection?.id == PreferredCar.customId {
                        customMake = selection?.make ?? ""
                        customModel = selection?.model ?? ""
                        customYear = selection?.year.map(String.init) ?? ""
                    }
                } label: {
                    HStack {
                        Text("Custom…")
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if selection?.id == PreferredCar.customId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
                .listRowBackground(Color.cardGray)
            }

            if selection != nil {
                Section {
                    Button("Clear selection", role: .destructive) {
                        selection = nil
                        PreferredCar.clear()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("My car")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCustom) {
            NavigationStack {
                Form {
                    TextField("Make", text: $customMake)
                    TextField("Model", text: $customModel)
                    TextField("Year", text: $customYear)
                        .keyboardType(.numberPad)
                }
                .navigationTitle("Custom car")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showCustom = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let year = Int(customYear)
                            let car = PreferredCar(
                                id: PreferredCar.customId,
                                make: customMake.trimmingCharacters(in: .whitespaces),
                                model: customModel.trimmingCharacters(in: .whitespaces),
                                year: year
                            )
                            guard !car.make.isEmpty, !car.model.isEmpty else { return }
                            selection = car
                            car.save()
                            showCustom = false
                        }
                        .disabled(customMake.trimmingCharacters(in: .whitespaces).isEmpty
                                  || customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Default dashboard

private struct DefaultDashboardPreview: View {
    var face: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardFaces.name(for: face).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.muted)
                .kerning(1)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RPM")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.muted)
                    Text("9545")
                        .font(.numeral(28, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPEED")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.muted)
                    Text("53")
                        .font(.numeral(28, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    + Text(" mph")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct DefaultDashboardPicker: View {
    @Binding var selection: Int

    var body: some View {
        List {
            ForEach(DashboardFaces.names.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    HStack {
                        Text(DashboardFaces.names[index])
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if selection == index {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
                .listRowBackground(Color.cardGray)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("Default dashboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}
