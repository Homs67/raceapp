//
//  TracksView.swift
//  raceApp
//
//  The track library tab. Circuits that ship with the app plus everything
//  made here: an autocross course marked on foot at the event, or a circuit
//  drawn on the satellite map. Sessions find their track by themselves after
//  the drive; this is where tracks are made, checked and corrected.
//

import SwiftUI
import MapKit
import CoreLocation
import SessionKit

struct TracksView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath(TracksView.debugInitialPath())
    @State private var showNew = false
    @State private var stats: [String: TrackStats] = [:]
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    /// Tracks waiting on the delete confirmation.
    @State private var pendingDelete: [Track] = []

    static func debugInitialPath() -> [String] {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-track-detail"),
           i + 1 < CommandLine.arguments.count {
            return [CommandLine.arguments[i + 1]]
        }
        #endif
        return []
    }

    private var userTracks: [Track] { model.tracks.all.filter(\.isUserTrack) }
    private var bundled: [Track] { model.tracks.all.filter { !$0.isUserTrack } }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenPageTitle(title: isSelecting ? selectedTitle : "Tracks")
                        .padding(.top, 4)
                    sectionTitle("Custom tracks")
                    if userTracks.isEmpty {
                        Text("Add a circuit or a point-to-point course: tap +, find the place, and drop the lines on the map or mark them where you stand.")
                            .font(.system(size: 13)).foregroundStyle(Color.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        grid(userTracks, deletable: true)
                    }
                    sectionTitle("Circuits")
                    grid(bundled, deletable: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.bgScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !userTracks.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting.toggle()
                                if !isSelecting { selectedIds.removeAll() }
                            }
                        } label: {
                            Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .accessibilityLabel(isSelecting ? "Done selecting" : "Select tracks")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button(role: .destructive) {
                            pendingDelete = userTracks.filter { selectedIds.contains($0.id) }
                        } label: { DestructiveToolbarIcon(enabled: !selectedIds.isEmpty) }
                        .disabled(selectedIds.isEmpty)
                        .accessibilityLabel("Delete selected")
                    } else {
                        Button { showNew = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New track")
                    }
                }
            }
            // `presenting:` hands the alert its own copy: the binding is
            // cleared as the alert closes, before the button's action runs.
            .alert(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                      set: { if !$0 { pendingDelete = [] } }),
                   presenting: pendingDelete) { tracks in
                Button("Delete", role: .destructive) { delete(tracks) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Sessions keep their times and the track's name, but won't be re-timed.")
            }
            .onChange(of: userTracks.isEmpty) { _, empty in
                if empty { isSelecting = false; selectedIds.removeAll() }
            }
            .navigationDestination(for: String.self) { id in
                if let track = model.tracks.track(id: id) {
                    TrackDetailView(track: track)
                }
            }
            .navigationDestination(for: TrackEditorRoute.self) { route in
                TrackEditorView(track: route.track)
            }
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionId: id)
            }
            .navigationDestination(for: TrackSessionsRoute.self) { route in
                TrackSessionsList(route: route)
            }
            .fullScreenCover(isPresented: $showNew) {
                NewTrackFlow { saved in path.append(saved.id) }
                    .environment(model)
            }
        }
        .task(id: "\(model.tracks.version)-\(model.recording.sessionsVersion)") { stats = TrackStats.compute(model.store.list()) }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.numeral(20, weight: .bold))
            .foregroundStyle(Color(hex: 0x8A8A8A))
            .padding(.top, 18)
            .padding(.bottom, 10)
    }

    private var selectedTitle: String {
        selectedIds.isEmpty ? "Select" : "\(selectedIds.count) Selected"
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \u{201C}\(pendingDelete[0].name)\u{201D}?" : "Delete \(pendingDelete.count) tracks?"
    }

    /// Custom tracks can be selected and deleted; bundled circuits can't, so
    /// they dim while selecting.
    private func grid(_ tracks: [Track], deletable: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(tracks) { track in
                if isSelecting {
                    Button {
                        guard deletable else { return }
                        if selectedIds.contains(track.id) { selectedIds.remove(track.id) } else { selectedIds.insert(track.id) }
                    } label: {
                        TrackCard(track: track, stats: stats[track.id])
                            .overlay(alignment: .topTrailing) {
                                if deletable {
                                    Image(systemName: selectedIds.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(selectedIds.contains(track.id) ? Color.accent : Color.muted)
                                        .background(Circle().fill(Color.cardBg))
                                        .padding(10)
                                }
                            }
                            .overlay {
                                if selectedIds.contains(track.id) {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.accent, lineWidth: 2)
                                }
                            }
                            .opacity(deletable ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                    .disabled(!deletable)
                } else {
                    NavigationLink(value: track.id) {
                        TrackCard(track: track, stats: stats[track.id])
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if deletable {
                            Button(role: .destructive) { pendingDelete = [track] } label: {
                                DestructiveLabel("Delete")
                            }
                        }
                    }
                }
            }
        }
    }

    private func delete(_ tracks: [Track]) {
        for track in tracks {
            model.tracks.delete(id: track.id)
            selectedIds.remove(track.id)
        }
        pendingDelete = []
        if selectedIds.isEmpty { isSelecting = false }
    }
}

/// Session count, best time and where the best run was, per track, from
/// the sessions' cached runs.
struct TrackStats {
    struct BestRun: Equatable {
        var session: UUID
        var start: TimeInterval
        var end: TimeInterval
    }
    var sessions = 0
    var best: TimeInterval?
    var bestRun: BestRun?
    /// Completed laps or runs across every session.
    var laps = 0
    var lastVisit: Date?
    /// Best of the latest visit minus best of the one before (negative = faster).
    var lastVisitDelta: TimeInterval?

    static func compute(_ manifests: [SessionManifest]) -> [String: TrackStats] {
        var out: [String: TrackStats] = [:]
        var visits: [String: [(date: Date, best: TimeInterval)]] = [:]
        for m in manifests {
            guard let ref = m.track, !ref.id.isEmpty else { continue }
            var s = out[ref.id] ?? TrackStats()
            s.sessions += 1
            s.lastVisit = max(s.lastVisit ?? .distantPast, m.startedAtUTC)
            var sessionBest: TimeInterval?
            for run in ref.runs where run.kind != .dnf {
                guard let end = run.end else { continue }
                s.laps += 1
                sessionBest = min(sessionBest ?? .infinity, end - run.start)
                guard end - run.start < (s.best ?? .infinity) else { continue }
                s.best = end - run.start
                s.bestRun = BestRun(session: m.id, start: run.start, end: end)
            }
            if let sessionBest { visits[ref.id, default: []].append((m.startedAtUTC, sessionBest)) }
            out[ref.id] = s
        }
        for (id, v) in visits where v.count > 1 {
            let sorted = v.sorted { $0.date < $1.date }
            out[id]?.lastVisitDelta = sorted[sorted.count - 1].best - sorted[sorted.count - 2].best
        }
        return out
    }
}

/// Navigation value for the editor (a track snapshot, pushed by id string).
struct TrackEditorRoute: Hashable {
    let track: Track
    var id: String { "edit:" + track.id }
    static func == (a: Self, b: Self) -> Bool { a.track.id == b.track.id }
    func hash(into h: inout Hasher) { h.combine(track.id) }
}

enum RunFormat {
    /// 0:24.31 or 1:52.07
    static func time(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let m = Int(total) / 60
        return String(format: "%d:%05.2f", m, total - Double(m * 60))
    }
}

/// Satellite map with the track's lines and, optionally, a driven trace.
struct TrackGatesMap: View {
    let track: Track?
    let trace: [CLLocationCoordinate2D]
    var layout: CourseLayout? = nil

    private var gates: CourseLayout? { layout ?? track?.layout ?? track?.startGate.map { CourseLayout(start: $0) } }

    var body: some View {
        Map(initialPosition: .region(region)) {
            if let track, track.centerline.count > 2 {
                MapPolyline(coordinates: track.centerlineCoordinates).stroke(Color.white.opacity(0.35), lineWidth: 2)
            }
            if trace.count > 1 {
                MapPolyline(coordinates: trace).stroke(Color.accent, lineWidth: 2.5)
            }
            if let g = gates?.start {
                GateMapContent(gate: g, color: .green, label: gates?.finish == nil ? "Start/finish" : "Start")
            }
            if let g = gates?.finish {
                GateMapContent(gate: g, color: .white, label: "Finish")
            }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }

    private var region: MKCoordinateRegion {
        var pts: [CLLocationCoordinate2D] = trace
        if let g = gates?.start { pts.append(.init(latitude: g.lat, longitude: g.lon)) }
        if let g = gates?.finish { pts.append(.init(latitude: g.lat, longitude: g.lon)) }
        if pts.count < 2, let track, track.centerline.count > 2 { pts += track.centerlineCoordinates }
        return MapRegion.fitting(pts, minSpanMeters: 150)
    }
}

/// A gate as a line plus a direction arrow.
struct GateMapContent: MapContent {
    let gate: TimingGate
    let color: Color
    let label: String
    /// Being edited: a soft glow under the line, as in the line editor.
    var selected = false
    /// Tapping the direction badge (the line editor selects the gate).
    var onTap: (() -> Void)? = nil

    var body: some MapContent {
        let e = gate.endpoints
        let ends: [CLLocationCoordinate2D] = [.init(latitude: e.a.lat, longitude: e.a.lon), .init(latitude: e.b.lat, longitude: e.b.lon)]
        if selected {
            MapPolyline(coordinates: ends)
                .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 16, lineCap: .round))
        }
        MapPolyline(coordinates: ends)
            .stroke(.black.opacity(0.45), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        MapPolyline(coordinates: ends)
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Annotation(label, coordinate: .init(latitude: gate.lat, longitude: gate.lon), anchor: .center) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(color)
                .rotationEffect(.degrees(gate.headingDegrees))
                .padding(4)
                .background(.black.opacity(0.55), in: Circle())
                .padding(8)
                .contentShape(Circle())
                .onTapGesture { onTap?() }
                .allowsHitTesting(onTap != nil)
        }
    }
}

enum MapRegion {
    static func fitting(_ pts: [CLLocationCoordinate2D], minSpanMeters: Double) -> MKCoordinateRegion {
        guard let first = pts.first else {
            return MKCoordinateRegion(center: .init(latitude: 37.33, longitude: -122.01),
                                      latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in pts {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let minDeg = minSpanMeters / 111_000
        return MKCoordinateRegion(center: center,
                                  span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, minDeg),
                                              longitudeDelta: max((maxLon - minLon) * 1.4, minDeg)))
    }
}
