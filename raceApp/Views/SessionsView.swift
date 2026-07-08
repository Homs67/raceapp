//
//  SessionsView.swift
//  raceApp
//
//  Sessions list + detail (design screens 5–6): highlights, map trace,
//  note, per-channel counts with gaps, export, delete.
//

import SwiftUI
import MapKit
import SessionKit

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @State private var sessions: [SessionManifest] = []
    @State private var pendingDelete: SessionManifest?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "flag.checkered",
                        description: Text("Press Start on the Record tab — every session lands here.")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session, metric: metric)
                            }
                            .listRowBackground(Color.cardBg)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    pendingDelete = session
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.bgScreen)
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(storageText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.muted)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionId: id)
            }
            .confirmationDialog(
                "Delete this session? The recorded data can't be recovered.",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Session", role: .destructive) {
                    if let session = pendingDelete {
                        try? model.store.delete(session.id)
                        model.recording.sessionUpdated()
                    }
                    pendingDelete = nil
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.recording.sessionsVersion) { reload() }
    }

    private func reload() {
        sessions = model.store.list()
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: model.store.totalStorageBytes(), countStyle: .file)
    }
}

private struct SessionRow: View {
    let session: SessionManifest
    let metric: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.locationName ?? "Session")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if session.status == .recovered {
                        badge("RECOVERED", color: .warnAmber)
                    }
                    if session.phoneOnly {
                        badge("NO OBD", color: .mutedStrong)
                    }
                }
                Text(session.startedAtUTC.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(durationText)
                    .font(.numeral(16, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text(distanceText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.muted)
            }
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        let seconds = Int(session.highlights?.durationSeconds ?? 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var distanceText: String {
        let units = UnitsFormatter(metric: metric)
        let distance = units.distance(fromMeters: session.highlights?.distanceMeters ?? 0)
        return String(format: "%.1f %@", distance, units.distanceUnit)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.microLabel(8)).kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    let sessionId: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false

    @State private var manifest: SessionManifest?
    @State private var trace: [CLLocationCoordinate2D] = []
    @State private var note = ""
    @State private var exportUrls: [URL]?
    @State private var exporting = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            if let manifest {
                VStack(alignment: .leading, spacing: 16) {
                    header(manifest)
                    if !trace.isEmpty { mapCard }
                    highlightsGrid(manifest)
                    noteField(manifest)
                    channelsCard(manifest)
                    exportButton
                    deleteButton
                }
                .padding(22)
            }
        }
        .background(Color.bgScreen)
        .navigationTitle(manifest?.locationName ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(isPresented: Binding(get: { exportUrls != nil }, set: { if !$0 { exportUrls = nil } })) {
            if let urls = exportUrls {
                ActivityView(items: urls)
            }
        }
        .confirmationDialog("Delete this session? The recorded data can't be recovered.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                try? model.store.delete(sessionId)
                model.recording.sessionUpdated()
                dismiss()
            }
        }
    }

    private func load() {
        manifest = try? model.store.manifest(for: sessionId)
        note = manifest?.note ?? ""
        let directory = model.store.directory(for: sessionId)
        Task.detached {
            let lats = ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: directory)
            let lons = ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: directory)
            let count = min(lats.count, lons.count)
            guard count > 1 else { return }
            let stride = Swift.max(1, count / 1500)
            var coords: [CLLocationCoordinate2D] = []
            var index = 0
            while index < count {
                coords.append(.init(latitude: lats[index].value, longitude: lons[index].value))
                index += stride
            }
            let finalCoords = coords
            await MainActor.run { trace = finalCoords }
        }
    }

    private func header(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(manifest.startedAtUTC.formatted(date: .long, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedStrong)
                if manifest.status == .recovered {
                    Text("RECOVERED")
                        .font(.microLabel(8)).kerning(0.8)
                        .foregroundStyle(Color.warnAmber)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.warnAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            if let car = manifest.car, let make = car.make {
                Text("\(make) \(car.model ?? "") · \(car.vin ?? "")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.muted)
            }
        }
    }

    private var mapCard: some View {
        Map {
            MapPolyline(coordinates: trace)
                .stroke(Color.accentCyan, lineWidth: 2.5)
            if let first = trace.first {
                Annotation("", coordinate: first) {
                    Circle().fill(Color.okGreen).frame(width: 9, height: 9)
                }
            }
            if let last = trace.last {
                Annotation("", coordinate: last) {
                    Rectangle().fill(Color.recordRed).frame(width: 8, height: 8)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardBorder, lineWidth: 1))
        .allowsHitTesting(false)
    }

    private func highlightsGrid(_ manifest: SessionManifest) -> some View {
        let units = UnitsFormatter(metric: metric)
        let h = manifest.highlights ?? .init()
        let tiles: [(String, String, Color)] = [
            ("DURATION", formatDuration(h.durationSeconds), .textPrimary),
            ("DISTANCE", String(format: "%.1f %@", units.distance(fromMeters: h.distanceMeters), units.distanceUnit), .textPrimary),
            ("MAX SPEED", String(format: "%.0f %@", units.speed(fromMps: h.maxSpeedMps), units.speedUnit.lowercased()), .textPrimary),
            ("AVG SPEED", String(format: "%.0f %@", units.speed(fromMps: h.avgSpeedMps), units.speedUnit.lowercased()), .textPrimary),
            ("MAX RPM", String(Int(h.maxRpm)), .textPrimary),
            ("PEAK LAT G", String(format: "%.2f g", h.peakLatG), .warnAmber),
            ("PEAK LONG G", String(format: "%.2f g", h.peakLongG), .warnAmber),
            ("ELEV GAIN", String(format: "%.0f %@", units.shortDistance(fromMeters: h.elevationGainMeters), units.shortDistanceUnit), .accentCyan),
            ("COOLANT", coolantRange(h, units: units), .textPrimary),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tiles, id: \.0) { tile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.0)
                        .font(.microLabel(8.5)).kerning(1)
                        .foregroundStyle(Color.muted)
                    Text(tile.1)
                        .font(.numeral(18, weight: .medium))
                        .foregroundStyle(tile.2)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder, lineWidth: 1))
            }
        }
    }

    private func noteField(_ manifest: SessionManifest) -> some View {
        TextField("Add a note — tires, pressures, conditions…", text: $note, axis: .vertical)
            .font(.system(size: 13))
            .padding(12)
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardBorder, lineWidth: 1))
            .onSubmit { saveNote() }
            .onChange(of: note) { saveNoteDebounced() }
    }

    @State private var noteSaveTask: Task<Void, Never>?
    private func saveNoteDebounced() {
        noteSaveTask?.cancel()
        noteSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveNote() }
        }
    }

    private func saveNote() {
        guard var manifest else { return }
        manifest.note = note.isEmpty ? nil : note
        try? model.store.save(manifest)
        self.manifest = manifest
    }

    private func channelsCard(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHANNELS")
                .font(.microLabel(9)).kerning(1.2)
                .foregroundStyle(Color.muted)
            ForEach(manifest.channels, id: \.id) { channel in
                HStack {
                    Text(channel.id.rawValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text("\(channel.sampleCount.formatted())")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Color.mutedStrong)
                    gapLabel(for: channel, manifest: manifest)
                }
            }
        }
        .padding(14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func gapLabel(for channel: SessionManifest.ChannelSummary, manifest: SessionManifest) -> some View {
        if channel.id.rawValue.hasPrefix("obd."), !manifest.obdGaps.isEmpty {
            let total = manifest.obdGaps.reduce(0) { $0 + $1.duration }
            Text("\(manifest.obdGaps.count) gap\(manifest.obdGaps.count == 1 ? "" : "s") · \(String(format: "%.1f", total)) s")
                .font(.system(size: 10))
                .foregroundStyle(Color.warnAmber)
        } else {
            Text("clean")
                .font(.system(size: 10))
                .foregroundStyle(Color.okGreen.opacity(0.8))
        }
    }

    private var exportButton: some View {
        Button {
            export()
        } label: {
            HStack {
                if exporting { ProgressView().tint(.black) }
                Text("Export — CSV + JSON")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(exporting)
    }

    private func export() {
        guard let manifest else { return }
        exporting = true
        let directory = model.store.directory(for: sessionId)
        Task.detached {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(manifest.id.uuidString)")
            let files = try? SessionExporter.exportFiles(
                manifest: manifest, sessionDirectory: directory, to: output)
            await MainActor.run {
                exporting = false
                if let files { exportUrls = [files.csv, files.json] }
            }
        }
    }

    private var deleteButton: some View {
        Button("Delete session…", role: .destructive) {
            confirmingDelete = true
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func coolantRange(_ h: SessionManifest.Highlights, units: UnitsFormatter) -> String {
        guard let min = h.coolantMinC, let max = h.coolantMaxC else { return "—" }
        return "\(Int(units.temp(fromC: min)))–\(Int(units.temp(fromC: max)))\(units.tempUnit)"
    }
}

/// Native share sheet wrapper.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
