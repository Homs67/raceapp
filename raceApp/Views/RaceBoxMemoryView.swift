//
//  RaceBoxMemoryView.swift
//  raceApp
//
//  What the logger has recorded on its own, and getting it off.
//
//  The device holds one continuous log rather than files, so there is
//  nothing to browse until it has been downloaded: this screen reports how
//  full the memory is, then imports everything into Sessions, where the
//  usual lap/graph/export tooling applies.
//

import SwiftUI
import SessionKit
import RaceBoxKit

struct RaceBoxMemoryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @State private var confirmErase = false
    /// Drives ticked in the preview. Everything starts selected.
    @State private var selectedDrives: Set<UUID> = []

    private var rb: RaceBoxController { model.raceBox }
    private var status: RaceBoxRecordingStatus? { rb.recordingStatus }

    var body: some View {
        List {
            if rb.state == .connected {
                if rb.deviceInfo?.supportsStandaloneRecording == false {
                    unsupportedSection
                } else {
                    memorySection
                    taskSection
                    actionsSection
                }
            } else {
                Section {
                    Text("Connect a RaceBox to see what it has recorded.")
                        .font(.system(size: 14)).foregroundStyle(Color.muted)
                }
                .listRowBackground(Color.cardBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle("RaceBox Memory")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.accent)
        .onAppear { rb.refreshMemoryStatus() }
        .alert("Erase all recorded data?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { rb.eraseStoredData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything stored on the RaceBox is deleted. Download first if you want to keep it. This can take a few minutes.")
        }
    }

    @ViewBuilder
    private var unsupportedSection: some View {
        Section {
            Text("This RaceBox has no internal memory — it streams to the phone only. The Mini S and Micro can record on their own.")
                .font(.system(size: 14)).foregroundStyle(Color.muted)
        }
        .listRowBackground(Color.cardBg)
    }

    @ViewBuilder
    private var memorySection: some View {
        Section("On the device") {
            if let status {
                LabeledContent("Memory used") { Text("\(status.memoryLevelPercent)%") }
                LabeledContent("Records stored") { Text(records(status.storedMessages)) }
                if let hours = estimatedDuration(status) {
                    LabeledContent("Approx. driving time") { Text(hours) }
                }
                LabeledContent("Recording now") { Text(status.isRecording ? "Yes" : "No") }
                if status.securityEnabled && !status.memoryUnlocked {
                    Text("Memory is locked with a security code set in the RaceBox app. Unlock it there before downloading.")
                        .font(.system(size: 12)).foregroundStyle(Color.warnAmber)
                }
            } else {
                Text("Reading…").font(.system(size: 14)).foregroundStyle(Color.muted)
            }
        }
        .font(.system(size: 14))
        .listRowBackground(Color.cardBg)
        .textCase(nil)
    }

    @ViewBuilder
    private var taskSection: some View {
        switch rb.memoryTask {
        case .idle:
            EmptyView()
        case .downloading(let received, let expected, let drives):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading… \(records(UInt32(received)))\(expected > 0 ? " of \(records(UInt32(expected)))" : "")")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if expected > 0 {
                        ProgressView(value: Double(received), total: Double(expected))
                            .tint(Color.accent)
                    } else {
                        ProgressView().tint(Color.accent)
                    }
                    Text("\(drives) drive\(drives == 1 ? "" : "s") so far. Keep the RaceBox in range — live data pauses while this runs.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                .padding(.vertical, 2)
                Button("Stop") { rb.cancelMemoryTask() }
                    .font(.system(size: 14)).foregroundStyle(Color.recordRed)
            }
            .listRowBackground(Color.cardBg)
        case .erasing(let percent):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Erasing… \(percent)%").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    ProgressView(value: Double(percent), total: 100).tint(Color.accent)
                    Text("A full memory takes a few minutes. Keep the RaceBox powered and in range.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                .padding(.vertical, 2)
                Button("Stop") { rb.cancelMemoryTask() }
                    .font(.system(size: 14)).foregroundStyle(Color.recordRed)
            }
            .listRowBackground(Color.cardBg)
        case .erased(let recordCount):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Device memory erased")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(recordCount > 0 ? "\(records(UInt32(recordCount))) records removed." : "It was already empty.")
                        .font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                .padding(.vertical, 2)
                Button("OK") { rb.clearMemoryResult() }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accent)
            }
            .listRowBackground(Color.cardBg)
        case .preview(let drives):
            Section {
                ForEach(drives) { drive in
                    DrivePreviewRow(drive: drive, metric: metric,
                                    selected: selectedDrives.contains(drive.id)) {
                        if selectedDrives.contains(drive.id) {
                            selectedDrives.remove(drive.id)
                        } else {
                            selectedDrives.insert(drive.id)
                        }
                    }
                }
            } header: {
                Text("\(drives.count) drive\(drives.count == 1 ? "" : "s") on the device")
            } footer: {
                Text("Nothing is in Sessions yet. Untick a drive to leave it out — it stays on the RaceBox until you erase the memory.")
            }
            .listRowBackground(Color.cardBg)
            .onAppear { selectedDrives = Set(drives.map(\.id)) }
            Section {
                Button(selectedDrives.isEmpty ? "Import nothing" : "Import \(selectedDrives.count) drive\(selectedDrives.count == 1 ? "" : "s")") {
                    model.importStagedRaceBoxDrives(selectedDrives)
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accent)
                .disabled(selectedDrives.isEmpty)
                Button("Discard download") { model.discardStagedRaceBoxDrives() }
                    .font(.system(size: 14)).foregroundStyle(Color.recordRed)
            }
            .listRowBackground(Color.cardBg)
        case .finished(let drives, let recordCount):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(drives > 0
                         ? "Imported \(drives) drive\(drives == 1 ? "" : "s")"
                         : "Nothing to import")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if recordCount > 0 {
                        Text("\(records(UInt32(recordCount))) records. They're in Sessions now, with laps, graphs and export.")
                            .font(.system(size: 12)).foregroundStyle(Color.muted)
                    }
                }
                .padding(.vertical, 2)
                Button("OK") { rb.clearMemoryResult() }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accent)
            }
            .listRowBackground(Color.cardBg)
        case .failed(let reason):
            Section {
                Text("Failed — \(reason)").font(.system(size: 14)).foregroundStyle(Color.warnAmber)
                Button("OK") { rb.clearMemoryResult() }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accent)
            }
            .listRowBackground(Color.cardBg)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if case .idle = rb.memoryTask {
            Section {
                Button("Download and preview") {
                    model.importRaceBoxMemory()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accent)
                .disabled((status?.storedMessages ?? 0) == 0)

                Button("Erase device memory") { confirmErase = true }
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recordRed)
            } footer: {
                Text("The RaceBox stores one continuous log. Separate drives are recovered from its start/stop markers and from gaps between records, then imported as individual sessions.")
            }
            .listRowBackground(Color.cardBg)
        }
    }

    private func records(_ count: UInt32) -> String {
        let n = Int(count)
        return n >= 1000
            ? (NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal))
            : "\(n)"
    }

    /// Records are written at the configured rate (25 Hz by default), so the
    /// count converts straight to time.
    private func estimatedDuration(_ status: RaceBoxRecordingStatus) -> String? {
        guard status.storedMessages > 0 else { return nil }
        let seconds = Double(status.storedMessages) / 25
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}


/// One recovered drive: route thumbnail, when, how long, how far, how fast.
private struct DrivePreviewRow: View {
    let drive: RaceBoxController.DrivePreview
    let metric: Bool
    let selected: Bool
    let toggle: () -> Void

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM · HH:mm"
        return f
    }()

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Color.accent : Color.muted)
                RouteTrace(points: drive.trace)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.when.string(from: drive.startedAt))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        let units = UnitsFormatter(metric: metric)
        let minutes = Int(drive.durationSeconds / 60)
        let seconds = Int(drive.durationSeconds) % 60
        let distance = units.distance(fromMeters: drive.distanceMeters)
        let top = units.speed(fromMps: drive.maxSpeedMps)
        var parts = [String(format: "%d:%02d", minutes, seconds)]
        if distance >= 0.05 { parts.append(String(format: "%.1f %@", distance, units.distanceUnit)) }
        if top >= 1 { parts.append(String(format: "top %.0f %@", top, units.speedUnit.lowercased())) }
        if drive.trace.isEmpty { parts.append("no GPS fix") }
        return parts.joined(separator: " · ")
    }
}

/// Tiny route outline, scaled to fit, no map underneath.
private struct RouteTrace: View {
    let points: [RaceBoxController.DrivePreview.Point]

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else {
                let r: CGFloat = 4
                ctx.fill(Path(ellipseIn: CGRect(x: size.width / 2 - r, y: size.height / 2 - r,
                                                width: 2 * r, height: 2 * r)),
                         with: .color(Color.muted))
                return
            }
            let lats = points.map(\.lat), lons = points.map(\.lon)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let midLat = (minLat + maxLat) / 2
            let lonScale = cos(midLat * .pi / 180)
            let spanX = max((maxLon - minLon) * lonScale, 1e-6)
            let spanY = max(maxLat - minLat, 1e-6)
            let pad: CGFloat = 4
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY)
            let w = spanX * scale, h = spanY * scale
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            var path = Path()
            for (i, p) in points.enumerated() {
                let x = ox + ((p.lon - minLon) * lonScale) * scale
                let y = oy + (maxLat - p.lat) * scale
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(Color.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
