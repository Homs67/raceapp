//
//  SessionsView.swift
//  raceApp
//
//  Sessions list + detail (design screens 5–6): highlights, map trace,
//  note, per-channel counts with gaps, export, delete.
//

import SwiftUI
import MapKit
import Charts
import PhotosUI
import SessionKit
import ObdKit

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @State private var sessions: [SessionManifest] = []
    @State private var pendingDelete: SessionManifest?
    @State private var path: [UUID] = []
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack(path: $path) {
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
        if LaunchArgs.openLatestSession, !didAutoOpen, let latest = sessions.first {
            didAutoOpen = true
            path = [latest.id]
        }
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
    @State private var gValidation: GForceValidation?
    @State private var graphs: [MetricSeries] = []
    @State private var loadingGraphs = true
    @State private var expandedSeries: MetricSeries?
    @State private var note = ""
    @State private var exportUrls: [URL]?
    @State private var exporting = false
    @State private var confirmingDelete = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var importingVideos = false
    @State private var showVideoPlayer = false

    var body: some View {
        ScrollView {
            if let manifest {
                VStack(alignment: .leading, spacing: 16) {
                    header(manifest)
                    if !trace.isEmpty { mapCard }
                    highlightsGrid(manifest)
                    videoSection(manifest)
                    if let gValidation { GCalibrationCard(validation: gValidation) }
                    graphsSection
                    noteField(manifest)
                    exportButton
                }
                .padding(22)
            }
        }
        .background(Color.bgScreen)
        .navigationTitle(manifest?.locationName ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Session", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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
        .fullScreenCover(isPresented: $showVideoPlayer) {
            SessionVideoView(sessionId: sessionId)
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoItems, matching: .videos)
        .onChange(of: photoItems) { importPickedPhotos() }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    // MARK: - Video section

    @ViewBuilder
    private func videoSection(_ manifest: SessionManifest) -> some View {
        let videos = manifest.videos ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VIDEO")
                    .font(.microLabel(9)).kerning(1.2)
                    .foregroundStyle(Color.muted)
                Spacer()
                if importingVideos {
                    ProgressView().tint(.gray).scaleEffect(0.7)
                } else {
                    addVideoMenu(compact: !videos.isEmpty)
                }
            }
            if !videos.isEmpty {
                Button {
                    showVideoPlayer = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch with data")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text(coverageText(videos, manifest: manifest))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.muted)
                    }
                }
                .buttonStyle(.plain)
                ForEach(videos) { asset in
                    videoRow(asset, manifest: manifest)
                }
            }
        }
        .padding(14)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 16))
    }

    private func addVideoMenu(compact: Bool) -> some View {
        Menu {
            Button("From Photos", systemImage: "photo.on.rectangle") { showPhotosPicker = true }
            Button("From Files", systemImage: "folder") { showFileImporter = true }
        } label: {
            if compact {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accent)
            } else {
                Text("Add videos")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accent)
            }
        }
    }

    private func videoRow(_ asset: VideoAsset, manifest: SessionManifest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.fileName.split(separator: "-").dropFirst().joined(separator: "-"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.mutedStrong)
                    .lineLimit(1)
                // Diagnosis line: the clock we read from the file (or the lack of one)
                if asset.hasEmbeddedDate == false {
                    Text("no clock in file — placed at session start, use Sync")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.recordRed)
                } else {
                    Text("camera clock: \(asset.wallClockStart.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.muted)
                }
            }
            Spacer()
            Text(placementText(asset, manifest: manifest))
                .font(.system(size: 10))
                .foregroundStyle(placementText(asset, manifest: manifest) == "outside session"
                                 ? Color.recordRed : Color.muted)
            Button {
                deleteVideo(asset)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muted)
            }
            .buttonStyle(.plain)
        }
    }

    private func coverageText(_ videos: [VideoAsset], manifest: SessionManifest) -> String {
        let duration = manifest.highlights?.durationSeconds ?? 0
        let segments = VideoTimeline.segments(assets: videos, sessionStartUTC: manifest.startedAtUTC,
                                              sessionDuration: duration,
                                              syncOffset: manifest.videoSyncOffset ?? 0)
        let coverage = VideoTimeline.coverage(segments: segments, sessionDuration: duration)
        let size = ByteCountFormatter.string(fromByteCount: VideoLibrary.totalBytes(videos), countStyle: .file)
        return "\(videos.count) clip\(videos.count == 1 ? "" : "s") · covers \(Int(coverage * 100))% of session · \(size)"
    }

    private func placementText(_ asset: VideoAsset, manifest: SessionManifest) -> String {
        let duration = manifest.highlights?.durationSeconds ?? 0
        let start = asset.wallClockStart.timeIntervalSince(manifest.startedAtUTC)
            + (manifest.videoSyncOffset ?? 0)
        let end = start + asset.duration
        guard end > 0, start < duration else { return "outside session" }
        func fmt(_ t: TimeInterval) -> String {
            let s = Int(max(0, min(duration, t)))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return "\(fmt(start))–\(fmt(end))"
    }

    // MARK: - Import

    private func importPickedPhotos() {
        guard !photoItems.isEmpty else { return }
        let items = photoItems
        photoItems = []
        importingVideos = true
        Task {
            for item in items {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await importOne(from: movie.url)
                    try? FileManager.default.removeItem(at: movie.url)
                }
            }
            importingVideos = false
        }
    }

    private func importFiles(_ urls: [URL]) {
        importingVideos = true
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                await importOne(from: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            importingVideos = false
        }
    }

    private func importOne(from url: URL) async {
        guard var manifest else { return }
        let directory = model.store.directory(for: sessionId)
        guard let asset = try? await VideoLibrary.importVideo(
            from: url, sessionDirectory: directory, fallbackStart: manifest.startedAtUTC) else { return }
        manifest.videos = (manifest.videos ?? []) + [asset]
        try? model.store.save(manifest)
        self.manifest = manifest
        model.recording.sessionUpdated()
    }

    private func deleteVideo(_ asset: VideoAsset) {
        guard var manifest else { return }
        VideoLibrary.deleteFile(for: asset, sessionDirectory: model.store.directory(for: sessionId))
        manifest.videos = (manifest.videos ?? []).filter { $0.id != asset.id }
        try? model.store.save(manifest)
        self.manifest = manifest
        model.recording.sessionUpdated()
    }

    private func load() {
        let loaded = try? model.store.manifest(for: sessionId)
        manifest = loaded
        note = loaded?.note ?? ""
        if LaunchArgs.openLatestVideo, loaded?.videos?.isEmpty == false, !showVideoPlayer {
            showVideoPlayer = true
        }
        let directory = model.store.directory(for: sessionId)
        let metric = self.metric
        Task.detached {
            let lats = ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: directory)
            let lons = ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: directory)
            let count = min(lats.count, lons.count)
            var coords: [CLLocationCoordinate2D] = []
            if count > 1 {
                let stride = Swift.max(1, count / 1500)
                var index = 0
                while index < count {
                    coords.append(.init(latitude: lats[index].value, longitude: lons[index].value))
                    index += stride
                }
            }
            let series = loaded.map { MetricSeries.build(directory: directory, manifest: $0, metric: metric) } ?? []
            let validation = GForceValidation.validate(sessionDirectory: directory)
            let finalCoords = coords
            await MainActor.run {
                trace = finalCoords
                graphs = series
                gValidation = validation
                loadingGraphs = false
                if LaunchArgs.openLatestGraph, expandedSeries == nil {
                    expandedSeries = series.first
                }
            }
        }
    }

    @ViewBuilder private var graphsSection: some View {
        if !graphs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("GRAPHS")
                    .font(.microLabel(9)).kerning(1.2)
                    .foregroundStyle(Color.muted)
                ForEach(graphs) { series in
                    Button { expandedSeries = series } label: {
                        MetricChart(series: series)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(item: $expandedSeries) { series in
                FullGraphView(series: series)
            }
        } else if loadingGraphs {
            HStack { Spacer(); ProgressView().tint(.gray); Spacer() }
                .frame(height: 80)
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

// MARK: - G calibration verdict

/// Physics cross-check card: was the calibrated G data consistent with GPS?
private struct GCalibrationCard: View {
    let validation: GForceValidation

    private var title: String {
        switch validation.verdict {
        case .verified: return "Verified against GPS"
        case .marginal: return "Marginal — partially consistent"
        case .failed: return "Failed — inconsistent with GPS"
        case .noCalibratedData: return "No calibrated data"
        case .insufficientData: return "Not enough speed variation to verify"
        }
    }

    private var color: Color {
        switch validation.verdict {
        case .verified: return .accent
        case .marginal, .insufficientData, .noCalibratedData: return .mutedStrong
        case .failed: return .recordRed
        }
    }

    private var detail: String? {
        switch validation.verdict {
        case .noCalibratedData:
            return "Recorded before mount calibration completed — G values are raw phone-frame."
        case .insufficientData:
            return "Verification needs some acceleration and braking during the session."
        default:
            var parts: [String] = []
            if let r = validation.longCorrelation, let s = validation.longScale {
                parts.append(String(format: "Longitudinal vs GPS: r %.2f · scale %.2f · %d windows",
                                    r, s, validation.pairCount))
            }
            if let latR = validation.latCorrelation {
                parts.append(String(format: "Cornering vs GPS course-rate: r %.2f", latR))
            }
            if let lag = validation.gpsLagSeconds, lag > 0 {
                parts.append(String(format: "GPS lag compensation: %.1f s", lag))
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("G CALIBRATION")
                    .font(.microLabel(9)).kerning(1.2)
                    .foregroundStyle(Color.muted)
                Spacer()
            }
            HStack(spacing: 7) {
                Image(systemName: validation.verdict == .verified ? "checkmark.seal.fill"
                      : validation.verdict == .failed ? "xmark.seal.fill" : "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.mutedStrong)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Session graphs

struct SeriesPoint: Identifiable {
    let x: Double   // seconds since session start
    let y: Double
    var id: Double { x }
}

/// One plotted metric over the whole session. Built off-main by bucket-averaging
/// the raw channel down to ~360 points so charts stay smooth on long sessions.
struct MetricSeries: Identifiable {
    let id: String
    let title: String
    let unit: String
    let color: Color
    let points: [SeriesPoint]
    /// High-resolution points (~5 Hz) for the live rolling-window video graph;
    /// the 360-bucket `points` stay coarse for full-session overviews.
    var finePoints: [SeriesPoint] = []
    var symmetricZero = false   // G channels: draw a zero baseline, center the axis

    /// Stable y-range for live mode so the axis doesn't jump as the window slides.
    var yDomain: ClosedRange<Double> {
        let ys = points.map(\.y)
        guard var lo = ys.min(), var hi = ys.max() else { return 0...1 }
        if symmetricZero {
            let bound = max(abs(lo), abs(hi), 0.1) * 1.1
            return -bound...bound
        }
        let pad = max((hi - lo) * 0.08, 0.5)
        lo -= pad
        hi += pad
        return min(lo, 0)...hi
    }

    static func build(directory: URL, manifest: SessionManifest, metric: Bool) -> [MetricSeries] {
        let units = UnitsFormatter(metric: metric)
        let start = manifest.startUptime
        let duration = manifest.highlights?.durationSeconds ?? 0
        guard duration > 0 else { return [] }
        let buckets = 360
        let fineBuckets = min(6000, max(buckets, Int(duration * 5))) // ~5 Hz

        func series(_ id: String, _ title: String, _ unit: String, _ color: Color,
                    _ channel: ChannelId, symmetricZero: Bool = false,
                    transform: (Double) -> Double = { $0 }) -> MetricSeries? {
            let samples = ChannelReader.samples(for: channel, inSessionDirectory: directory)
            guard !samples.isEmpty else { return nil }
            func bucketize(_ count: Int) -> [SeriesPoint] {
                var sums = [Double](repeating: 0, count: count)
                var counts = [Int](repeating: 0, count: count)
                for sample in samples {
                    let elapsed = sample.t - start
                    guard elapsed >= 0, elapsed <= duration else { continue }
                    let bucket = min(count - 1, Int(elapsed / duration * Double(count)))
                    sums[bucket] += transform(sample.value)
                    counts[bucket] += 1
                }
                var points: [SeriesPoint] = []
                for bucket in 0..<count where counts[bucket] > 0 {
                    let x = (Double(bucket) + 0.5) / Double(count) * duration
                    points.append(SeriesPoint(x: x, y: sums[bucket] / Double(counts[bucket])))
                }
                return points
            }
            let points = bucketize(buckets)
            guard points.count > 1 else { return nil }
            return MetricSeries(id: id, title: title, unit: unit, color: color,
                                points: points, finePoints: bucketize(fineBuckets),
                                symmetricZero: symmetricZero)
        }

        var result: [MetricSeries] = []

        // Speed — prefer OBD (km/h) then GPS (m/s)
        if let s = series("speed", "Speed", units.speedUnit.lowercased(), .accent, .obd(.speed),
                          transform: { units.speed(fromKmh: $0) })
            ?? series("speed", "Speed", units.speedUnit.lowercased(), .accent, .gpsSpeed,
                      transform: { units.speed(fromMps: $0) }) {
            result.append(s)
        }
        if let s = series("rpm", "RPM", "rpm", .textPrimary, .obd(.rpm)) { result.append(s) }
        if let s = series("throttle", "Throttle", "%", .accent, .obd(.throttle)) { result.append(s) }
        // Longitudinal g = acceleration (+) and braking (−); our brake proxy (no OBD
        // brake channel). Prefer auto-calibrated car-frame G; fall back to raw axes
        // for sessions recorded before calibration completed.
        if let s = series("longg", "Acceleration & Braking", "g", .recordRed, .carLongG, symmetricZero: true)
            ?? series("longg", "Acceleration & Braking (uncal.)", "g", .recordRed, .imuAccelY, symmetricZero: true) {
            result.append(s)
        }
        if let s = series("latg", "Cornering", "g", .textPrimary, .carLatG, symmetricZero: true)
            ?? series("latg", "Cornering (uncal.)", "g", .textPrimary, .imuAccelX, symmetricZero: true) {
            result.append(s)
        }
        if let s = series("elev", "Elevation", units.shortDistanceUnit, .mutedStrong, .baroRelativeAltitude,
                          transform: { units.shortDistance(fromMeters: $0) }) { result.append(s) }
        if let s = series("load", "Engine Load", "%", .accent, .obd(.engineLoad)) { result.append(s) }
        if let s = series("coolant", "Coolant Temp", units.tempUnit, .recordRed, .obd(.coolantTemp),
                          transform: { units.temp(fromC: $0) }) { result.append(s) }
        return result
    }
}

private struct MetricChart: View {
    let series: MetricSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(series.unit)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muted)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muted)
            }

            Chart {
                if series.symmetricZero {
                    RuleMark(y: .value("zero", 0))
                        .foregroundStyle(Color.white.opacity(0.12))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(series.points) { point in
                    LineMark(x: .value("t", point.x), y: .value("v", point.y))
                        .foregroundStyle(series.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(timeLabel(seconds))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.muted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Color.muted)
                }
            }
            .frame(height: 110)
        }
        .padding(14)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 16))
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Full-screen graph with a horizontally scrollable time axis for detail.
private struct FullGraphView: View {
    let series: MetricSeries
    @Environment(\.dismiss) private var dismiss

    /// Show a window of the session at a time so scrolling reveals detail.
    private var window: Double {
        let total = series.points.last?.x ?? 0
        guard total > 0 else { return 1 }
        return min(total, max(15, total * 0.3))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scroll left and right to explore. Values in \(series.unit).")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muted)
                    .padding(.horizontal)

                Chart {
                    if series.symmetricZero {
                        RuleMark(y: .value("zero", 0))
                            .foregroundStyle(Color.white.opacity(0.15))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    ForEach(series.points) { point in
                        LineMark(x: .value("t", point.x), y: .value("v", point.y))
                            .foregroundStyle(series.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: window)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(timeLabel(seconds))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.muted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                        AxisValueLabel()
                            .font(.system(size: 10))
                            .foregroundStyle(Color.muted)
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Color.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
