//
//  RaceBoxDeviceView.swift
//  raceApp
//
//  Everything about the logger, on one page: the device itself, whether it is
//  working, and the four things you can do to it.
//

import SwiftUI
import BleKit
import RaceBoxKit
import SessionKit

struct RaceBoxDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCalibration = false
    @State private var onScreen = false

    private var rb: RaceBoxController { model.raceBox }
    private var status: DeviceLinkStatus { .raceBox(rb) }

    var body: some View {
        Group {
            if status.kind == .connected {
                ScrollView {
                    VStack(spacing: 0) {
                        topBar
                        hero.frame(height: 260).padding(.top, 8)
                        if RaceBoxMesh.shell != nil {
                            Text("↻ drag to spin")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mutedWeak)
                                .padding(.top, 2)
                        }
                        titleBlock.padding(.top, 20)
                        connectedBody
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            } else {
                // Nothing to scroll to, so the page uses the screen: actions
                // on the bottom edge where the thumb is, the name and status
                // just above them, and the case centred in what is left.
                VStack(spacing: 0) {
                    topBar
                    hero.frame(maxWidth: .infinity, maxHeight: .infinity)
                    titleBlock
                    actions.padding(.top, 28)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(Color.bgScreen.ignoresSafeArea())
        // Own top bar, so section titles never slide under a floating button.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCalibration) {
            GCalibrationView().environment(model)
        }
        .task { rb.refreshMemoryStatus() }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            MapGlassButton(symbol: "chevron.left") { dismiss() }
            Spacer()
            Menu {
                NavigationLink(value: "racebox-signals") { Label("Signals", systemImage: "waveform") }
                if rb.state.isConnected {
                    Button("Disconnect") { rb.disconnect(); dismiss() }
                }
                Button("Forget this device", role: .destructive) { rb.forget(); dismiss() }
            } label: {
                MapGlassLabel(symbol: "ellipsis")
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var hero: some View {
        DeviceHero(dimmed: status.kind != .connected) {
            if RaceBoxMesh.shell != nil {
                // Face-up while we are looking for it: there is nothing to
                // inspect, so the case reads as a silhouette and stops turning.
                RaceBoxRenderView(pose: status.kind == .connected ? .angled : .top,
                                  turntable: status.kind == .connected ? 28 : nil,
                                  isVisible: onScreen && !showCalibration
                                             && scenePhase == .active)
            } else {
                DeviceImageHero(artwork: status.kind == .connected
                                ? "RaceBoxHero" : "RaceBoxHeroTop")
            }
        }
    }

    private var titleBlock: some View {
        DeviceTitleBlock(title: rb.deviceInfo?.model?.rawValue ?? "RaceBox",
                         subtitle: rb.deviceInfo?.serialNumber,
                         status: status)
    }

    // MARK: - Connected

    @ViewBuilder
    private var connectedBody: some View {
        DeviceSectionTitle(text: "Health")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            DeviceTile(icon: "location.north.line.fill", label: "GPS",
                       value: (rb.latest?.hasValidFix ?? false) ? "3D fix" : "No fix",
                       caption: rb.latest.map { "\($0.satellites) satellites" })
            DeviceTile(icon: "bolt.fill", label: "Power",
                       value: rb.loggerPower?.shortText ?? "—",
                       caption: rb.loggerPower?.explanation ?? powerCaption)
            DeviceTile(icon: "waveform.path.ecg", label: "Update rate",
                       value: rb.stats.measuredHz >= 1 ? "\(Int(rb.stats.measuredHz.rounded())) Hz" : "—",
                       caption: rb.dataStalled ? "stalled" : "steady")
            DeviceTile(icon: "scope", label: "Accuracy",
                       value: rb.latest.map { String(format: "±%.1f m", $0.horizontalAccuracy) } ?? "—",
                       caption: "horizontal")
        }

        DeviceSectionTitle(text: "Calibration")
        DeviceRowGroup {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: calibrated ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(calibrated ? Color.linkGreen : Color.accent)
                    Text(calibrated ? "G-sensor calibrated" : "G-sensor not calibrated")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                Text(calibrationDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .padding(.leading, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Button { showCalibration = true } label: {
                Text(calibrated ? "Recalibrate" : "Calibrate")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }

        DeviceSectionTitle(text: "Memory & firmware")
        DeviceRowGroup {
            if rb.deviceInfo?.supportsStandaloneRecording != false {
                NavigationLink(value: "racebox-memory") {
                    DeviceRow(icon: "externaldrive", label: "Recorded on device", showsChevron: true) {
                        Text(memorySummary)
                    }
                }
                .buttonStyle(.plain)
                DeviceRowDivider()
            }
            DeviceRow(icon: "cpu", label: "Firmware") {
                Text(rb.deviceInfo?.firmware?.description ?? "—")
            }
            DeviceRowDivider()
            DeviceRow(icon: "number", label: "Serial number") {
                Text(rb.deviceInfo?.serialNumber ?? "—")
            }
        }

        Button { rb.forget(); dismiss() } label: {
            Text("Forget this device")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recordRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 28)
    }

    // MARK: - Searching / not connected

    @ViewBuilder
    private var actions: some View {
        Button(action: primaryAction) {
            Text(primaryLabel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(status.isBusy || rb.bluetoothRadio == .unsupported)
        .opacity(rb.bluetoothRadio == .unsupported ? 0.4 : 1)

        Button { dismiss() } label: {
            Text("Use phone GPS for now")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accent)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Copy

    /// Scanning again cannot help when the radio is the thing that is off, so
    /// the button goes where the fix actually is.
    private var radioNeedsSettings: Bool {
        rb.bluetoothRadio == .poweredOff || rb.bluetoothRadio == .unauthorized
    }

    private var primaryLabel: String {
        if radioNeedsSettings { return "Open Settings" }
        return status.isBusy ? "Searching…" : "Try again"
    }

    private func primaryAction() {
        guard !radioNeedsSettings else {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }
        rb.start()
    }

    private var calibrated: Bool { rb.framePhase == .calibrated }

    private var calibrationDetail: String {
        switch rb.framePhase {
        case .leveling: return "Park, hold still, then take a short drive."
        case .aligning: return "Needs a few straight-line pulls to finish."
        case .calibrated:
            let when = rb.frameCalibratedAt.map {
                "Levelled " + $0.formatted(.dateTime.month(.abbreviated).day())
            }
            let quality = (rb.frameQuality?.isTrustworthy ?? true) ? "aligned on a drive" : "still improving"
            return [when, quality].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The Micro has no battery; say what the rail is instead of implying one.
    private var powerCaption: String? {
        switch rb.loggerPower {
        case .supply(_, .vehicle, _): return "car 12 V"
        case .supply(_, .usb, _): return "USB"
        case .cell: return "cell"
        case .battery: return "internal"
        default: return nil
        }
    }

    private var memorySummary: String {
        guard let s = rb.recordingStatus else { return "—" }
        let minutes = s.storedMessages / 25 / 60
        return minutes > 0 ? "\(s.memoryLevelPercent)% · ≈\(minutes) min" : "\(s.memoryLevelPercent)%"
    }
}
