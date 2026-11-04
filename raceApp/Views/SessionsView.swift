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
    @State private var path: [UUID] = []
    @State private var didAutoOpen = false
    @State private var isSelecting = false
    @State private var selectedIds: Set<UUID> = []

    private var obdConnected: Bool {
        model.connection.adapterLinkUp
    }

    private var raceBoxConnected: Bool {
        model.raceBox.state == .connected
    }

    var body: some View {
        VStack(spacing: 0) {
            if path.isEmpty {
                OBDConnectionStatusBar(connected: obdConnected, raceBox: raceBoxConnected) {
                    model.showSettings = true
                }
            }

            NavigationStack(path: $path) {
                Group {
                    if sessions.isEmpty && !model.recording.isRecording {
                        VStack(alignment: .leading, spacing: 0) {
                            sessionsHeader
                            Spacer(minLength: 0)
                            ContentUnavailableView(
                                "No Sessions",
                                systemImage: "flag.checkered",
                                description: Text("Press Start below — every session lands here.")
                            )
                            Spacer(minLength: 0)
                        }
                    } else {
                        List {
                            sessionsHeader
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)

                            ForEach(sessionSections) { section in
                                // Title as a normal row so it scrolls away (List section headers pin).
                                Text(section.title.uppercased())
                                    .font(.numeral(20, weight: .bold))
                                    .foregroundStyle(Color(hex: 0x8A8A8A))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 0, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)

                                ForEach(section.sessions) { session in
                                    sessionRow(for: session)
                                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                                .onDelete { offsets in
                                    guard !isSelecting else { return }
                                    deleteSessions(at: offsets, in: section)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .contentMargins(.horizontal, 0, for: .scrollContent)
                    }
                }
                .background(Color.bgScreen)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if !sessions.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isSelecting.toggle()
                                    if !isSelecting { selectedIds.removeAll() }
                                }
                            } label: {
                                Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                            }
                            .accessibilityLabel(isSelecting ? "Done selecting" : "Select sessions")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if isSelecting {
                            Button(role: .destructive) {
                                deleteSelectedSessions()
                            } label: {
                                DestructiveToolbarIcon(enabled: !selectedIds.isEmpty)
                            }
                            .disabled(selectedIds.isEmpty)
                            .accessibilityLabel("Delete selected")
                        } else if !CommandLine.arguments.contains("-seed-presentation") {   // clean screenshots for the talk
                            Button {
                                model.showDebug = true
                            } label: {
                                Image(systemName: "ladybug")
                            }
                            .accessibilityLabel("Debug")
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    SessionDetailView(sessionId: id)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !model.recording.isRecording && !isSelecting {
                        idleBottomChrome
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: model.recording.isRecording)
                .animation(.easeInOut(duration: 0.2), value: isSelecting)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.recording.sessionsVersion) { reload() }
    }

    private var selectedTitle: String {
        selectedIds.isEmpty ? "Select" : "\(selectedIds.count) Selected"
    }

    private var sessionsHeader: some View {
        ScreenPageTitle(title: isSelecting ? selectedTitle : "Sessions")
    }

    @ViewBuilder
    private func sessionRow(for session: SessionManifest) -> some View {
        if isSelecting {
            Button {
                toggleSelection(session.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedIds.contains(session.id)
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selectedIds.contains(session.id) ? Color.accent : Color.muted)
                    SessionCard(session: session, metric: metric)
                }
            }
            .buttonStyle(.plain)
        } else {
            // The link sits behind the card so List doesn't add its chevron.
            SessionCard(session: session, metric: metric)
                .background {
                    NavigationLink(value: session.id) { EmptyView() }.opacity(0)
                }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private var idleBottomChrome: some View {
        SessionStartButton()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }

    private var sessionSections: [SessionDateSection] {
        SessionDateSection.group(sessions)
    }

    private func reload() {
        sessions = model.store.list()
        if LaunchArgs.openLatestSession, !didAutoOpen,
           let latest = LaunchArgs.openSessionPrefix.flatMap({ p in sessions.first { $0.id.uuidString.hasPrefix(p) } }) ?? sessions.first {
            didAutoOpen = true
            path = [latest.id]
        }
    }

    private func deleteSessions(at offsets: IndexSet, in section: SessionDateSection) {
        delete(sessions: offsets.map { section.sessions[$0] })
    }

    private func deleteSelectedSessions() {
        let toDelete = sessions.filter { selectedIds.contains($0.id) }
        delete(sessions: toDelete)
        selectedIds.removeAll()
        isSelecting = false
    }

    private func delete(sessions toDelete: [SessionManifest]) {
        let ids = Set(toDelete.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
        for session in toDelete {
            try? model.store.delete(session.id)
            SessionThumbnails.shared.remove(session.id)
            path.removeAll { $0 == session.id }
        }
        model.recording.sessionUpdated()
    }
}

/// Exclusive date buckets for the Sessions list: Today, Last 7 days, then
/// one per month ("October 2026"). Empty buckets are omitted.
private struct SessionDateSection: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionManifest]

    static func group(_ sessions: [SessionManifest], now: Date = Date(),
                      calendar: Calendar = .current) -> [SessionDateSection] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfLast7 = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var today: [SessionManifest] = []
        var last7: [SessionManifest] = []
        var byMonth: [Date: [SessionManifest]] = [:] // keyed by month start

        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAtUTC)
            if day >= startOfToday {
                today.append(session)
            } else if day >= startOfLast7 {
                last7.append(session)
            } else {
                let comps = calendar.dateComponents([.year, .month], from: day)
                let monthStart = calendar.date(from: comps) ?? day
                byMonth[monthStart, default: []].append(session)
            }
        }

        var sections: [SessionDateSection] = []
        if !today.isEmpty {
            sections.append(.init(id: "today", title: "Today", sessions: today))
        }
        if !last7.isEmpty {
            sections.append(.init(id: "last7", title: "Last 7 days", sessions: last7))
        }
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "MMMM yyyy"
        for monthStart in byMonth.keys.sorted(by: >) {
            sections.append(.init(id: "month-\(monthStart.timeIntervalSince1970)",
                                  title: monthFormatter.string(from: monthStart),
                                  sessions: byMonth[monthStart] ?? []))
        }
        return sections
    }
}

// MARK: - OBD status (under status bar)

private struct OBDConnectionStatusBar: View {
    var connected: Bool
    var raceBox = false
    var onTapDisconnected: () -> Void

    private let connectedGreen = Color(hex: 0x30D158)

    /// Any live link keeps the bar dark; only "nothing connected" goes orange.
    private var anyLink: Bool { connected || raceBox }

    private var text: String {
        switch (connected, raceBox) {
        case (true, true): return "OBD II + RaceBox connected"
        case (true, false): return "OBD II connected"
        case (false, true): return "RaceBox connected · no OBD II"
        case (false, false): return "OBD II is not connected"
        }
    }

    var body: some View {
        Button {
            if !connected { onTapDisconnected() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: anyLink ? "wifi" : "wifi.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(anyLink ? connectedGreen : Color.black.opacity(0.75))
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(anyLink ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
                if !connected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connected)
        .accessibilityLabel(text)
        .background(barColor.ignoresSafeArea(edges: .top))
    }

    private var barColor: Color {
        anyLink ? .black : .accent
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    let sessionId: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false

    @State private var manifest: SessionManifest?
    @State private var analysis: SessionAnalysis?
    @State private var gValidation: GForceValidation?
    @State private var previousBest: TimeInterval?
    @State private var mapRoute: MapRoute?
    @State private var detailsExpanded = true
    @State private var note = ""
    @State private var exportUrls: [URL]?
    @State private var exporting = false
    @State private var confirmingDelete = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var importingVideos = false

    private struct MapRoute: Identifiable { let lapId: Int; var camera = false; var id: Int { lapId } }

    private var track: Track? {
        guard let id = manifest?.track?.id, !id.isEmpty else { return nil }
        return model.tracks.track(id: id)
    }

    var body: some View {
        ScrollView {
            if let manifest {
                VStack(alignment: .leading, spacing: 12) {
                    header(manifest)
                    if let analysis {
                        if !analysis.t.isEmpty {
                            SessionHeroMap(analysis: analysis, track: track, weather: manifest.weather)
                                .onTapGesture { openMap(analysis.bestLap) }
                            if manifest.weather != nil { WeatherAttributionRow() }
                        }
                        BestLapCard(analysis: analysis, manifest: manifest, previousBest: previousBest)
                        if !analysis.laps.isEmpty {
                            LapBarsCard(analysis: analysis) { openMap($0) }
                        }
                        if !analysis.drag.isEmpty {
                            DragCard(drag: analysis.drag, raceBox: !analysis.phoneGpsOnly)
                        }
                    } else {
                        HStack { Spacer(); ProgressView().tint(.gray); Spacer() }.frame(height: 236)
                    }
                    videoSection(manifest)
                    detailsSection(manifest)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.bgScreen)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { export() } label: {
                    if exporting { ProgressView() } else { Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon) }
                }
                .disabled(exporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        DestructiveLabel("Delete Session")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { load() }
        .onChange(of: model.recording.sessionsVersion) {
            manifest = try? model.store.manifest(for: sessionId)
        }
        .onChange(of: manifest?.track) { buildAnalysis() }
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
        .fullScreenCover(item: $mapRoute) { route in
            if let analysis {
                SessionTrackMapView(sessionId: sessionId, analysis: analysis, track: track, layout: manifest?.track?.layout,
                                    lapId: route.lapId, topView: route.camera ? .camera : .map)
            }
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoItems, matching: .videos)
        .onChange(of: photoItems) { importPickedPhotos() }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private func openMap(_ lap: SessionAnalysis.Lap?, camera: Bool = false) {
        guard let analysis, !analysis.t.isEmpty else { return }
        mapRoute = MapRoute(lapId: lap?.id ?? analysis.navigableLaps.first?.id ?? 0, camera: camera)
    }
    // MARK: - Video section

    @ViewBuilder
    private func videoSection(_ manifest: SessionManifest) -> some View {
        let videos = manifest.videos ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VIDEO")
                    .font(.microLabel(12)).kerning(1.2)
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
                    openMap(analysis?.bestLap, camera: true)
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
                                .font(.system(size: 12))
                                .foregroundStyle(Color.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.muted)
                    }
                }
                .buttonStyle(.plain)
                if videos.contains(where: { $0.hasEmbeddedDate == false }) {
                    Label("A clip has no clock — line it up in Video sync", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.recordRed)
                }
                DisclosureGroup("Clips (\(videos.count))") {
                    ForEach(videos) { asset in
                        videoRow(asset, manifest: manifest)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .tint(Color.mutedStrong)
            }
        }
        .padding(16)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
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
                HStack(spacing: 6) {
                    Text(videoRoleLabel(asset.role))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accent)
                    Text(asset.fileName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.mutedStrong)
                        .lineLimit(1)
                }
                // Diagnosis line: the clock we read from the file (or the lack of one)
                if asset.hasEmbeddedDate == false {
                    Text("no clock in file — placed at session start, use Sync")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recordRed)
                } else {
                    Text("phone clock: \(asset.wallClockStart.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                }
            }
            Spacer()
            Text(placementText(asset, manifest: manifest))
                .font(.system(size: 12))
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

    private func videoRoleLabel(_ role: VideoAsset.Role) -> String {
        switch role {
        case .rear: return "Rear"
        case .front: return "Front"
        case .imported: return "Import"
        }
    }

    private func coverageText(_ videos: [VideoAsset], manifest: SessionManifest) -> String {
        let duration = manifest.highlights?.durationSeconds ?? 0
        let primary = VideoTimeline.primaryPlaybackAssets(videos)
        let segments = VideoTimeline.segments(assets: primary, sessionStartUTC: manifest.startedAtUTC,
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
            if let updated = await VideoImporter.importPicked(items, sessionId: sessionId, model: model) { manifest = updated }
            importingVideos = false
        }
    }

    private func importFiles(_ urls: [URL]) {
        importingVideos = true
        Task {
            if let updated = await VideoImporter.importFiles(urls, sessionId: sessionId, model: model) { manifest = updated }
            importingVideos = false
        }
    }

    private func deleteVideo(_ asset: VideoAsset) {
        if let updated = VideoImporter.remove([asset.id], sessionId: sessionId, model: model) { manifest = updated }
    }

    private func load() {
        let loaded = try? model.store.manifest(for: sessionId)
        manifest = loaded
        if let loaded { model.retimeIfStale(loaded) }
        note = loaded?.note ?? ""
        let directory = model.store.directory(for: sessionId)
        Task.detached {
            let validation = GForceValidation.validate(sessionDirectory: directory)
            await MainActor.run { gValidation = validation }
        }
        buildAnalysis()
    }

    /// Laps, speed colours, brake zones and drag splits — rebuilt whenever the
    /// session is re-timed against its track.
    private func buildAnalysis() {
        guard let manifest else { return }
        let directory = model.store.directory(for: sessionId)
        let trackId = manifest.track?.id
        previousBest = trackId.flatMap { id in
            model.store.list().filter { $0.id != sessionId && $0.track?.id == id }.compactMap { $0.track?.best }.min()
        }
        let corners = track?.corners.map { ($0.name, $0.coordinate) } ?? []
        Task.detached {
            var built = SessionAnalysis.build(directory: directory, manifest: manifest, track: nil)
            await MainActor.run {
                built.corners = corners.map { (name: $0.0, coordinate: $0.1) }
                analysis = built
                fetchWeatherIfNeeded(built)
                let openVideo = LaunchArgs.openLatestVideo && manifest.videos?.isEmpty == false
                if LaunchArgs.openLatestGraph || openVideo, mapRoute == nil, !built.t.isEmpty {
                    mapRoute = MapRoute(lapId: built.bestLapId ?? built.navigableLaps.first?.id ?? 0, camera: openVideo)
                }
            }
        }
    }

    /// One Apple Weather request per session, saved into the manifest.
    private func fetchWeatherIfNeeded(_ built: SessionAnalysis) {
        guard manifest?.weather == nil, !built.t.isEmpty, !SessionWeather.attempted.contains(sessionId) else { return }
        SessionWeather.attempted.insert(sessionId)
        guard let snapshot = manifest else { return }
        // Where the car actually was: the best lap's start, else mid-drive. The first
        // fix can predate a good GPS lock (or, in demo replays, the replay itself).
        let start = built.coordinate(built.bestLap.map { built.indices($0).lowerBound } ?? built.t.count / 2)
        Task {
            do {
                guard let weather = try await SessionWeather.fetch(for: snapshot, at: start),
                      var fresh = try? model.store.manifest(for: sessionId) else { return }
                fresh.weather = weather
                try? model.store.save(fresh)
                manifest = fresh
            } catch {
                NSLog("[weather] %@ at %.5f,%.5f", String(describing: error), start.latitude, start.longitude)
            }
        }
    }

    private func header(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(manifest.locationName ?? track?.name ?? "Session")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                if manifest.status == .recovered {
                    Text("RECOVERED")
                        .font(.microLabel(12)).kerning(0.8)
                        .foregroundStyle(Color.warnAmber)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.warnAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(subtitle(manifest))
                .font(.system(size: 15))
                .foregroundStyle(Color.mutedStrong)
        }
        .padding(.top, 4)
    }

    private func subtitle(_ manifest: SessionManifest) -> String {
        var parts = [manifest.startedAtUTC.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     manifest.startedAtUTC.formatted(date: .omitted, time: .shortened)]
        if let car = manifest.car, let make = car.make { parts.append("\(make) \(car.model ?? "")".trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Details

    private func detailsSection(_ manifest: SessionManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DETAILS").font(.microLabel(11)).foregroundStyle(Color.muted)
                Spacer()
                Button(detailsExpanded ? "Hide" : "Show") { withAnimation { detailsExpanded.toggle() } }
                    .font(.system(size: 13, weight: .medium))
                    .tint(Color.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if detailsExpanded {
                VStack(spacing: 0) {
                    TrackDetailRow(sessionId: sessionId, manifest: manifest,
                                   start: analysis.flatMap { $0.t.isEmpty ? nil : $0.coordinate(0) })
                    divider
                    if let car = manifest.car, let make = car.make {
                        detailRow("Car", "\(make) \(car.model ?? "")\(car.vin.map { " · \($0)" } ?? "")", Color.muted)
                        divider
                    }
                    if let gValidation {
                        let v = gVerdict(gValidation)
                        detailRow("G calibration", v.0, v.1)
                        divider
                    }
                    let gaps = manifest.obdGaps.count + (manifest.sensorGaps?.count ?? 0)
                    detailRow("Sensor gaps", gaps == 0 ? "None" : "\(gaps)", Color.muted)
                    divider
                    TextField("Add a note — tires, pressures, conditions…", text: $note, axis: .vertical)
                        .font(.system(size: 16))
                        .padding(.vertical, 13)
                        .padding(.trailing, 16)
                        .onSubmit { saveNote() }
                        .onChange(of: note) { saveNoteDebounced() }
                }
                .padding(.leading, 16)
                .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
                .tint(Color.accent)
            }
        }
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5) }

    private func detailRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 16)).foregroundStyle(Color.textPrimary)
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.vertical, 13)
        .padding(.trailing, 16)
    }

    private func gVerdict(_ v: GForceValidation) -> (String, Color) {
        switch v.verdict {
        case .verified: return ("Verified", Color(hex: 0x30D158))
        case .marginal: return ("Marginal", .mutedStrong)
        case .failed: return ("Inconsistent with GPS", .recordRed)
        case .noCalibratedData: return ("Not calibrated", .muted)
        case .insufficientData: return ("Not enough data", .muted)
        }
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

    private func export() {
        guard let manifest else { return }
        exporting = true
        let directory = model.store.directory(for: sessionId)
        Task.detached {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(manifest.id.uuidString)")
            // CSV + JSON sidecar only. The raw native-rate dump is ten times
            // the size and nothing downstream needs it; it stays available
            // from the debug tools for sample-timing audits.
            let files = try? SessionExporter.exportLightFiles(
                manifest: manifest, sessionDirectory: directory, to: output)
            await MainActor.run {
                exporting = false
                if let files { exportUrls = [files.csv, files.json] }
            }
        }
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
        // RPM / throttle — prefer the 105 Hz broadcast-CAN channels when the
        // session recorded them, else the polled OBD channels.
        if let s = series("rpm", "RPM", "rpm", .textPrimary, .canRpm)
            ?? series("rpm", "RPM", "rpm", .textPrimary, .obd(.rpm)) {
            result.append(s)
        }
        if let s = series("throttle", "Throttle", "%", .accent, .canAccelPedal)
            ?? series("throttle", "Throttle", "%", .accent, .obd(.throttle)) {
            result.append(s)
        }
        // Broadcast-CAN driver inputs (OBD-II has no PIDs for these)
        if let s = series("steering", "Steering Angle", "°", .textPrimary, .canSteering,
                          symmetricZero: true) { result.append(s) }
        if let s = series("brake", "Brake", "%", .recordRed, .canBrake) { result.append(s) }
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

// MARK: - Track

/// Which track the session was on, with Change and Edit lines. Times follow
/// the track: edit its lines and the laps re-time.
private struct TrackDetailRow: View {
    @Environment(AppModel.self) private var model
    let sessionId: UUID
    let manifest: SessionManifest
    let start: CLLocationCoordinate2D?

    private var ref: SessionManifest.TrackRef? {
        guard let r = manifest.track, !r.id.isEmpty else { return nil }
        return r
    }
    private var track: Track? { ref.flatMap { model.tracks.track(id: $0.id) } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Track").font(.system(size: 16)).foregroundStyle(Color.textPrimary)
            Spacer()
            Text(ref.map { track?.name ?? "\($0.nameSnapshot) (deleted)" } ?? "None")
                .font(.system(size: 15)).foregroundStyle(Color.muted).lineLimit(1)
            if let track {
                NavigationLink {
                    TrackEditorView(track: track)
                } label: {
                    Image(systemName: "line.diagonal").font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Edit lines")
            }
            trackMenu
        }
        .padding(.vertical, 11)
        .padding(.trailing, 16)
    }

    private var trackMenu: some View {
        Menu {
            ForEach(nearbyTracks) { t in
                Button(t.name) { model.setTrack(t, for: sessionId) }
            }
            Divider()
            Button("Detect automatically", systemImage: "wand.and.stars") { model.autoDetectTrack(for: sessionId) }
            Button("No track", systemImage: "xmark") { model.setTrack(nil, for: sessionId) }
        } label: {
            Text(ref == nil ? "Assign" : "Change")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    /// Tracks nearest the start of the drive first.
    private var nearbyTracks: [Track] {
        let all = model.tracks.all.filter { $0.layout != nil || $0.isUserTrack }
        guard let p = start else { return all }
        let mLon = 111_320.0 * cos(p.latitude * .pi / 180)
        func d(_ t: Track) -> Double {
            guard let a = t.anchor else { return .infinity }
            let dx = (a.longitude - p.longitude) * mLon, dy = (a.latitude - p.latitude) * 110_540
            return dx * dx + dy * dy
        }
        return Array(all.sorted { d($0) < d($1) }.prefix(12))
    }
}
