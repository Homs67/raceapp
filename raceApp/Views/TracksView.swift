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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if userTracks.isEmpty {
                        Text("Add a course at your next event: tap + and mark the start and finish where you stand, or draw them on the map.")
                            .font(.system(size: 13)).foregroundStyle(Color.muted)
                    }
                    ForEach(userTracks) { track in
                        NavigationLink(value: track.id) { TrackRow(track: track, stats: stats[track.id]) }
                    }
                } header: { Text("My tracks") }
                Section {
                    ForEach(bundled) { track in
                        NavigationLink(value: track.id) { TrackRow(track: track, stats: stats[track.id]) }
                    }
                } header: { Text("Circuits") }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgScreen)
            .listRowBackground(Color.cardBg)
            .navigationTitle("Tracks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let track = model.tracks.track(id: id) {
                    TrackDetailView(track: track)
                }
            }
            .navigationDestination(for: TrackEditorRoute.self) { route in
                TrackEditorView(track: route.track)
            }
            .sheet(isPresented: $showNew) {
                NewTrackSheet { track in
                    model.tracks.save(track)
                    let saved = model.tracks.track(id: track.id) ?? track
                    path.append(saved.id)
                    path.append(TrackEditorRoute(track: saved))
                }
            }
        }
        .task(id: "\(model.tracks.version)-\(model.recording.sessionsVersion)") { stats = TrackStats.compute(model.store.list()) }
    }
}

/// Session count and best time per track, from the sessions' cached runs.
struct TrackStats {
    var sessions = 0
    var best: TimeInterval?

    static func compute(_ manifests: [SessionManifest]) -> [String: TrackStats] {
        var out: [String: TrackStats] = [:]
        for m in manifests {
            guard let ref = m.track, !ref.id.isEmpty else { continue }
            var s = out[ref.id] ?? TrackStats()
            s.sessions += 1
            if let b = ref.best { s.best = min(s.best ?? .infinity, b) }
            out[ref.id] = s
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

private struct TrackRow: View {
    let track: Track
    let stats: TrackStats?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            Spacer()
            if let best = stats?.best {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(RunFormat.time(best)).font(.numeral(15, weight: .medium)).foregroundStyle(Color.textPrimary)
                    Text("best").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = [track.trackKind == .autocross ? "Autocross" : "Circuit"]
        if track.isUserTrack, let d = track.createdAt { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        else if !track.location.isEmpty { parts.append(track.location) }
        if track.layout == nil { parts.append(track.trackKind == .autocross ? "gates not set" : "no line yet") }
        if let n = stats?.sessions, n > 0 { parts.append("\(n) session\(n == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum RunFormat {
    /// 0:24.31 or 1:52.07
    static func time(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let m = Int(total) / 60
        return String(format: "%d:%05.2f", m, total - Double(m * 60))
    }
}

// MARK: - New track

private struct NewTrackSheet: View {
    let create: (Track) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Track.Kind = .autocross
    @State private var name = ""

    private var defaultName: String {
        "\(kind == .autocross ? "Autocross" : "Circuit") · \(Date().formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Autocross").tag(Track.Kind.autocross)
                        Text("Circuit").tag(Track.Kind.circuit)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind == .autocross
                         ? "Separate start and finish lines. Each pass from one to the other is a run."
                         : "One line, crossed once per lap.")
                }
                Section("Name") {
                    TextField(defaultName, text: $name)
                }
                Section {
                    Label("Mark on site: walk to each line, tap Mark here", systemImage: "figure.walk")
                    Label("Or draw: tap the satellite map where the line is", systemImage: "map")
                } footer: {
                    Text("You can save before the lines are set and finish later. Sessions recorded near the track are matched to it automatically, even ones recorded before you made it.")
                }
                .font(.system(size: 13)).foregroundStyle(Color.muted)
            }
            .navigationTitle("New track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        create(Track.newUserTrack(name: trimmed.isEmpty ? defaultName : trimmed, kind: kind))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Detail

struct TrackDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var sessions: [SessionManifest] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var current: Track { model.tracks.track(id: track.id) ?? track }

    var body: some View {
        List {
            Section {
                TrackGatesMap(track: current, trace: [])
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                NavigationLink(value: TrackEditorRoute(track: editableCopy)) {
                    Label(current.layout == nil ? "Set the lines" : "Edit lines", systemImage: "line.diagonal")
                }
                if current.isUserTrack {
                    Button { newName = current.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete track", systemImage: "trash") }
                }
            } footer: {
                if !current.isUserTrack {
                    Text("Bundled from OpenStreetMap; the start/finish line is approximate. Editing it saves your own copy.")
                }
            }
            Section("Sessions") {
                if sessions.isEmpty {
                    Text("None yet. Drive here with recording on and sessions are matched automatically.")
                        .font(.system(size: 13)).foregroundStyle(Color.muted)
                }
                ForEach(sessions) { m in
                    HStack {
                        Text(m.startedAtUTC.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        let done = m.track?.runs.filter { $0.kind != .dnf }.count ?? 0
                        Text("\(done) \(current.trackKind == .autocross ? "run" : "lap")\(done == 1 ? "" : "s")")
                            .foregroundStyle(Color.muted)
                        if let best = m.track?.best { Text(RunFormat.time(best)).font(.numeral(14, weight: .medium)) }
                    }
                    .font(.system(size: 14))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.tracks.version)-\(model.recording.sessionsVersion)") {
            sessions = model.store.list().filter { $0.track?.id == track.id }
        }
        .alert("Rename track", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                var t = current
                t.name = newName
                model.tracks.save(t)
                model.trackDidChange(model.tracks.track(id: t.id) ?? t)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(current.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.tracks.delete(id: current.id)
                dismiss()
            }
        } message: {
            Text("Sessions keep their times and the track's name, but won't be re-timed.")
        }
    }

    /// Bundled tracks are edited as a user copy that shadows the original.
    private var editableCopy: Track {
        var t = current
        if !t.isUserTrack, t.startGate == nil, let layout = t.layout {
            t.startGate = layout.start
            t.kind = .circuit
        }
        return t
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

    var body: some MapContent {
        let e = gate.endpoints
        MapPolyline(coordinates: [.init(latitude: e.a.lat, longitude: e.a.lon), .init(latitude: e.b.lat, longitude: e.b.lon)])
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Annotation(label, coordinate: .init(latitude: gate.lat, longitude: gate.lon), anchor: .center) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(color)
                .rotationEffect(.degrees(gate.headingDegrees))
                .padding(4)
                .background(.black.opacity(0.55), in: Circle())
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
