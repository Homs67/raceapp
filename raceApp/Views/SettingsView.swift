//
//  SettingsView.swift
//  raceApp
//
//  Settings sheet: OBD adapter, preferences (car / shift / default dashboard),
//  and general units. Help + diagnostics live elsewhere.
//

import SwiftUI
import BleKit
import ObdKit
import SessionKit
import RaceBoxKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage("keepScreenAwake") private var keepAwake = false
    @AppStorage("shiftEnabled") private var shiftEnabled = false
    @AppStorage("shiftRPM") private var shiftRPM: Double = 5500
    @State private var preferredCar = PreferredCar.load()
    /// A RaceBox in range that has never been paired. Offered once per visit;
    /// "Not now" means not now.
    @State private var declinedPairing = false
    @State private var path = NavigationPath()

    private var connection: ConnectionController { model.connection }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ScreenPageTitle(title: "Settings")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                devicesSection
                preferencesSection
                generalSettingsSection
                experimentalSection
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
                case "racebox":
                    RaceBoxDeviceView()
                case "obd":
                    ObdDeviceView()
                case "racebox-signals":
                    RaceBoxDebugView()
                case "racebox-memory":
                    RaceBoxMemoryView().environment(model)
                default:
                    EmptyView()
                }
            }
            .onAppear { connection.beginAdapterDiscoveryIfNeeded() }
            .sheet(item: Binding(get: { pairable }, set: { if $0 == nil { declinedPairing = true } })) { device in
                ConnectSheet(device: device) {
                    #if DEBUG
                    if Self.pairDemo { model.raceBox.startSimulated(); return }
                    #endif
                    model.raceBox.select(device)
                } onDismiss: {
                    declinedPairing = true
                    model.raceBox.disconnect()
                }
                .environment(model)
            }
        }
    }

    // MARK: - Devices

    /// Two cards, one status line each. Everything that used to live here —
    /// adapter picker, RSSI, satellites, protocol, a button per branch of the
    /// state machine — is on the device pages now.
    /// Nothing remembered, something in range: worth asking about.
    #if DEBUG
    static let pairDemo = CommandLine.arguments.contains("-pair-demo")
    #endif

    private var pairable: DiscoveredAdapter? {
        #if DEBUG
        // `-pair-demo`: a RaceBox "in range" in the Simulator, so first pairing can be shown.
        if Self.pairDemo {
            guard !declinedPairing, !model.raceBox.isSimulated else { return nil }
            return DiscoveredAdapter(id: UUID(uuidString: "5ACEB0C5-0000-4000-8000-000000000001")!,
                                     name: "RaceBox Micro 3241500917", rssi: -48)
        }
        #endif
        guard !declinedPairing,
              model.raceBox.storedDeviceName == nil,
              case .scanning = model.raceBox.state else { return nil }
        return model.raceBox.discovered.first
    }

    private var devicesSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Button { path.append("racebox") } label: {
                    DeviceCard(title: "RaceBox",
                               artwork: "RaceBoxHero",
                               status: .raceBox(model.raceBox))
                }
                .buttonStyle(.plain)

                Button { path.append("obd") } label: {
                    DeviceCard(title: "OBD-II",
                               artwork: "ObdAdapter",
                               status: .obd(connection))
                }
                .buttonStyle(.plain)
            }
            // The List already insets its rows; adding our own put the cards
            // further from the edge than every other card in Settings.
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                Button {
                    connection.retryScan()
                    model.raceBox.start()
                } label: {
                    Text("+ Add")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
            }
            .textCase(nil)
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section("Preferences") {
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

            NavigationLink {
                DashboardsSettingsView()
            } label: {
                HStack(spacing: 12) {
                    if let current = model.dashboards.selected {
                        DashboardThumbnail(dashboard: current)
                            .frame(width: 72, height: 33)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dashboards")
                            .font(.system(size: 15))
                        Text("\(model.dashboards.dashboards.count) configured · long-press a widget to edit")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.muted)
                    }
                }
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

    private var experimentalSection: some View {
        Section {
            NavigationLink {
                CanMonitorView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CAN Monitor (beta)")
                            .font(.system(size: 15))
                        Text("Read advanced signals — steering, brake, pedal")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.muted)
                    }
                } icon: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .foregroundStyle(Color.accent)
                }
            }
            Toggle(isOn: Binding(
                get: { model.connection.canStreamEnabled },
                set: { model.connection.canStreamEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record CAN signals (beta)")
                        .font(.system(size: 15))
                    Text("Sessions capture steering, brake & pedal at 50–105 Hz instead of OBD polling")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                    if let mode = model.connection.canStreamMode {
                        Text("Streaming now: \(mode)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accent)
                    }
                }
            }
            .tint(Color.accent)
            Toggle(isOn: Binding(
                get: { model.cloudSync.isEnabled },
                set: { model.cloudSync.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save drives to iCloud Drive")
                        .font(.system(size: 15))
                    Text(model.cloudSync.status ?? "CSV + JSON of every session, in Files → iCloud Drive → raceApp → Drives")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                }
            }
            .tint(Color.accent)
        } header: {
            Text("Experimental")
        } footer: {
            Text("Listens to the car's CAN bus for data OBD-II can't provide. Currently maps the Mazda MX-5 ND. Read-only. The app first tries to watch every signal through one filter; if the adapter can't keep up it rotates between them a few times a second, and the dashboard holds the last value (dimmed) in between. Slow OBD data (coolant, fuel, voltage) is polled once a minute.\n\nBuild \(BuildInfo.description)")
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
                .font(.system(size: 12, weight: .bold)).monospacedDigit()
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

