//
//  RaceBoxDebugView.swift
//  raceApp
//
//  Verification screen for RaceBox devices: every decoded signal with its value,
//  unit and raw integer, link health, standalone-recording control, a pass/fail
//  self-test, and a shareable log. Read-only apart from recording commands.
//

import SwiftUI
import BleKit
import RaceBoxKit

struct RaceBoxDebugView: View {
    @Environment(AppModel.self) private var model

    private var controller: RaceBoxController { model.raceBox }

    var body: some View {
        List {
            connectionSection
            if controller.state.isConnected {
                if let message = controller.latest {
                    selfTestSection
                    fixSection(message)
                    positionSection(message)
                    motionSection(message)
                    sensorSection(message)
                    powerSection(message)
                } else {
                    Section {
                        Text("Connected — waiting for the first data message…")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mutedStrong)
                    }
                    .listRowBackground(Color.cardBg)
                }
                linkSection
                if controller.deviceInfo?.supportsStandaloneRecording == true { recordingSection }
                shareSection
            } else if !controller.discovered.isEmpty {
                discoveredSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("RaceBox")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { controller.start() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.state.isConnected ? Color.accent : Color.mutedWeak)
                    .frame(width: 8, height: 8)
                Text(controller.statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if controller.state.isConnected {
                    Button("Disconnect") { controller.disconnect() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.recordRed)
                } else {
                    Button("Scan") { controller.scan() }
                        .font(.system(size: 13, weight: .medium))
                }
            }

            if let info = controller.deviceInfo, controller.state.isConnected {
                row("Model", info.model?.rawValue ?? "unknown")
                row("Serial", info.serialNumber ?? "—")
                row("Firmware", info.firmware?.description ?? "—")
                row("Hardware", info.hardwareRevision ?? "—")
                row("Standalone recording", info.supportsStandaloneRecording ? "supported" : "not supported")
                row("GNSS config (fw 3.3+)", info.supportsGnssConfig ? "supported" : "not supported")
            }
        } header: {
            Text("Device")
        } footer: {
            if case .failed(let reason) = controller.state {
                Text(reason).foregroundStyle(Color.recordRed)
            } else if !controller.state.isConnected {
                Text("The RaceBox Micro has no battery — it only advertises with 12 V from the OBD port. It also stays hidden while connected to another app.")
            }
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private var discoveredSection: some View {
        Section {
            ForEach(controller.discovered) { device in
                Button {
                    controller.select(device)
                } label: {
                    HStack {
                        Text(device.name).font(.system(size: 14))
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Color.mutedStrong)
                    }
                }
            }
        } header: { Text("Found") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    // MARK: - Self-test

    private var selfTestSection: some View {
        Section {
            Button {
                controller.runSelfTest()
            } label: {
                Label("Run self-test", systemImage: "checkmark.seal")
                    .font(.system(size: 14, weight: .medium))
            }

            ForEach(controller.selfTestChecks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(for: check.status))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color(for: check.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.system(size: 13))
                        Text(check.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.muted)
                    }
                }
            }
        } header: {
            Text("Self-test")
        } footer: {
            if controller.selfTestRunAt != nil {
                let summary = controller.selfTestSummary
                Text("\(summary.passed) passed · \(summary.failed) failed · \(summary.skipped) skipped. At-rest checks are skipped while moving.")
                    .foregroundStyle(summary.failed > 0 ? Color.recordRed : Color.muted)
            } else {
                Text("Checks packet rate, framing, fix quality, clock agreement, gravity and gyro at rest, and input power.")
            }
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func icon(for status: RaceBoxSelfTest.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: RaceBoxSelfTest.Status) -> Color {
        switch status {
        case .pass: return .accent
        case .fail: return .recordRed
        case .skipped: return .mutedWeak
        }
    }

    // MARK: - Signal sections

    private func fixSection(_ m: RaceBoxDataMessage) -> some View {
        Section {
            row("Fix status", "\(m.fixStatus.rawValue)", raw: m.hasValidFix ? "valid" : "NOT valid",
                highlight: m.hasValidFix ? .accent : .recordRed)
            row("Satellites", "\(m.satellites)")
            row("PDOP", String(format: "%.2f", m.pdop))
            row("Horizontal accuracy", String(format: "±%.2f m", m.horizontalAccuracy))
            row("Vertical accuracy", String(format: "±%.2f m", m.verticalAccuracy))
            row("UTC", m.timestamp.map { Self.utc.string(from: $0) } ?? "—",
                raw: "iTOW \(m.iTOW)")
            row("Coordinates flag", m.coordinatesValid ? "valid" : "INVALID",
                raw: String(format: "0x%02X", m.latLonFlags))
        } header: { Text("Fix") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func positionSection(_ m: RaceBoxDataMessage) -> some View {
        Section {
            row("Latitude", String(format: "%.7f°", m.latitude))
            row("Longitude", String(format: "%.7f°", m.longitude))
            row("Altitude (MSL)", String(format: "%.2f m", m.mslAltitude))
            row("Altitude (WGS84)", String(format: "%.2f m", m.wgsAltitude))
        } header: { Text("Position") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func motionSection(_ m: RaceBoxDataMessage) -> some View {
        Section {
            row("Speed", String(format: "%.2f m/s", m.speedMps),
                raw: String(format: "%.1f mph · %.1f km/h", m.speedMps * 2.23694, m.speedMps * 3.6))
            row("Heading", String(format: "%.2f°", m.headingDegrees),
                raw: m.headingValid ? "valid" : "not valid")
            row("Speed accuracy", String(format: "±%.3f m/s", m.speedAccuracyMps))
            row("Heading accuracy", String(format: "±%.2f°", m.headingAccuracyDegrees))
        } header: { Text("Motion") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func sensorSection(_ m: RaceBoxDataMessage) -> some View {
        Section {
            axisBar("G · X (front/back)", value: m.gForce.x, range: 2, unit: "g")
            axisBar("G · Y (right/left)", value: m.gForce.y, range: 2, unit: "g")
            axisBar("G · Z (up/down)", value: m.gForce.z, range: 2, unit: "g")
            row("Magnitude", String(format: "%.3f g", m.gForce.magnitude))
            axisBar("Roll rate", value: m.rotationRate.x, range: 180, unit: "°/s")
            axisBar("Pitch rate", value: m.rotationRate.y, range: 180, unit: "°/s")
            axisBar("Yaw rate", value: m.rotationRate.z, range: 180, unit: "°/s")
        } header: { Text("Sensors") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    private func powerSection(_ m: RaceBoxDataMessage) -> some View {
        Section {
            switch m.power(for: controller.deviceInfo?.model ?? .micro) {
            case .inputVoltage(let volts):
                row("Input voltage", String(format: "%.1f V", volts),
                    raw: String(format: "0x%02X", m.powerByte),
                    highlight: (11...15).contains(volts) ? .textPrimary : .recordRed)
            case .battery(let percent, let charging):
                row("Battery", "\(percent)%", raw: charging ? "charging" : "on battery")
            }
        } header: { Text("Power") }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    // MARK: - Link health

    private var linkSection: some View {
        Section {
            let stats = controller.stats
            row("Measured rate", String(format: "%.1f Hz", stats.measuredHz),
                highlight: stats.measuredHz >= 20 ? .textPrimary : .recordRed)
            row("Data messages", "\(stats.dataMessages)")
            row("Packets parsed", "\(stats.packetsParsed)")
            row("Checksum failures", "\(stats.checksumFailures)",
                highlight: stats.checksumFailures == 0 ? .textPrimary : .recordRed)
            row("Bytes discarded", "\(stats.bytesDiscarded)",
                highlight: stats.bytesDiscarded == 0 ? .textPrimary : .recordRed)
            row("Largest notification", "\(stats.largestNotification) bytes")
        } header: {
            Text("Link health")
        } footer: {
            Text("Notifications split and merge packets, so checksum failures and discarded bytes are the proof that reassembly is correct.")
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    // MARK: - Standalone recording

    private var recordingSection: some View {
        Section {
            if let status = controller.recordingStatus {
                row("Recording", status.isRecording ? "YES" : "no",
                    highlight: status.isRecording ? .accent : .textPrimary)
                row("Memory used", "\(status.memoryLevelPercent)%",
                    raw: "\(status.storedMessages) / \(status.memorySizeMessages)")
                if let remaining = status.remainingSeconds(at: .hz25) {
                    row("Space left at 25 Hz", Self.duration(remaining))
                }
                row("Security", status.securityEnabled
                    ? (status.memoryUnlocked ? "enabled, unlocked" : "enabled, LOCKED")
                    : "off")
            }

            Button("Refresh status") {
                Task { await controller.refreshRecordingStatus() }
            }
            .font(.system(size: 14))

            if controller.recordingStatus?.isRecording == true {
                Button("Stop standalone recording") {
                    Task { await controller.setStandaloneRecording(false) }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.recordRed)
            } else {
                Button("Start — recommended filters") {
                    Task { await controller.setStandaloneRecording(true) }
                }
                .font(.system(size: 14, weight: .medium))
                Button("Start — standing starts (no stationary filter)") {
                    Task { await controller.setStandaloneRecording(true, standingStarts: true) }
                }
                .font(.system(size: 14))
            }
        } header: {
            Text("Standalone recording")
        } footer: {
            if let result = controller.lastCommandResult {
                Text(result).foregroundStyle(Color.accent)
            } else {
                Text("The device logs to its own memory with no phone connected. The stationary filter saves space but trims standing starts, so drag runs need the second option.")
            }
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    // MARK: - Share

    private var shareSection: some View {
        Section {
            if let url = controller.logFileURL() {
                ShareLink(item: url) {
                    Label("Share RaceBox log", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
            }
        } footer: {
            Text("Device info, link health, self-test results and a ~2 Hz sample log — for offline analysis.")
        }
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    // MARK: - Building blocks

    private func row(_ title: String, _ value: String,
                     raw: String? = nil, highlight: Color = .textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.mutedStrong)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(highlight)
                if let raw {
                    Text(raw)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.muted)
                }
            }
        }
    }

    /// Signed bar so a wrong axis or scale is obvious at a glance.
    private func axisBar(_ title: String, value: Double, range: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedStrong)
                Spacer()
                Text(String(format: "%+.3f %@", value, unit))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
            }
            GeometryReader { geometry in
                let half = geometry.size.width / 2
                let clamped = max(-range, min(range, value))
                let width = abs(clamped) / range * half
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1, height: 10)
                        .offset(x: half - 0.5, y: -3)
                    Rectangle()
                        .fill(Color.accent)
                        .frame(width: width, height: 4)
                        .offset(x: clamped >= 0 ? half : half - width)
                }
            }
            .frame(height: 10)
        }
        .padding(.vertical, 2)
    }

    private static let utc: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func duration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
