//
//  TrackDetailView.swift
//  raceApp
//
//  The track page (Figma Track App → "03 · Track preview", A3 row): name,
//  the drawn map with Navigate, headline numbers, your best here, the
//  sessions driven here as the same SessionCards the Sessions tab uses,
//  conditions now, and the named corners of a bundled circuit. Anything
//  we have no data for yet (elevation, lap record, corner notes) is left
//  out rather than shown empty.
//

import SwiftUI
import MapKit
import SessionKit

/// Every session on one track, pushed from "See all".
struct TrackSessionsRoute: Hashable {
    let trackId: String
}

struct TrackDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false
    let track: Track
    @State private var sessions: [SessionManifest] = []
    @State private var stats: TrackStats?
    @State private var weather: SessionManifest.WeatherSnapshot?
    @State private var showMap = false
    @State private var editing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var current: Track { model.tracks.track(id: track.id) ?? track }
    private var units: UnitsFormatter { UnitsFormatter(metric: metric) }
    private var isPointToPoint: Bool { current.trackKind == .autocross }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                titleBlock.padding(.top, 14)
                TrackMapCard(track: current, stats: stats,
                             directory: stats?.bestRun.map { model.store.directory(for: $0.session) }) { showMap = true }
                    .padding(.top, 18)
                statsRow.padding(.top, 22)
                if let stats, stats.best != nil { yourBest(stats) }
                sessionsSection
                if let weather { conditions(weather) }
                if !namedCorners.isEmpty { cornersSection }
                if !current.isUserTrack {
                    Text("Bundled from OpenStreetMap; the start/finish line is approximate. Editing it saves your own copy.")
                        .font(.system(size: 12)).foregroundStyle(Color.mutedWeak)
                        .padding(.top, 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color.bgScreen)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(model.tracks.version)-\(model.recording.sessionsVersion)") {
            let all = model.store.list()
            sessions = all.filter { $0.track?.id == track.id }.sorted { $0.startedAtUTC > $1.startedAtUTC }
            stats = TrackStats.compute(sessions)[track.id]
        }
        .task(id: track.id) {
            guard let anchor = current.anchor else { return }
            weather = try? await SessionWeather.current(at: anchor)
        }
        .fullScreenCover(isPresented: $showMap) { TrackFullMapView(track: current) }
        .navigationDestination(isPresented: $editing) { TrackEditorView(track: editableCopy) }
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

    // MARK: Header

    private var topBar: some View {
        HStack(spacing: 10) {
            MapGlassButton(symbol: "chevron.left") { dismiss() }
                .accessibilityLabel("Back")
            Spacer()
            Menu {
                Button(current.layout == nil ? "Set the lines" : "Edit lines", systemImage: "line.diagonal") { editing = true }
                if current.isUserTrack {
                    Button("Rename", systemImage: "pencil") { newName = current.name; renaming = true }
                    Button("Delete track", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            } label: {
                MapGlassLabel(symbol: "pencil")
            }
            .accessibilityLabel("Edit track")
            if let url = mapsURL {
                ShareLink(item: url, subject: Text(current.name)) { MapGlassLabel(symbol: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            }
        }
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.name.uppercased())
                .font(.numeral(46, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.mutedStrong)
            }
        }
    }

    private var subtitle: String {
        let first = current.isUserTrack ? current.trackKind.title : current.configuration
        return [first, current.location].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var mapsURL: URL? {
        guard let a = current.anchor else { return nil }
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(a.latitude),\(a.longitude)"), URLQueryItem(name: "q", value: current.name)]
        return c?.url
    }

    // MARK: Numbers

    @ViewBuilder private var statsRow: some View {
        let items: [(label: String, value: String, unit: String?)] = [
            current.lengthMeters > 0
                ? ((isPointToPoint ? "Course length" : "Circuit length"),
                   String(format: "%.2f", units.distance(fromMeters: current.lengthMeters)), units.distanceUnit)
                : nil,
            current.turnCount > 0 ? ("Turns", "\(current.turnCount)", nil) : nil,
        ].compactMap { $0 }
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                ForEach(items, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label).font(.system(size: 13)).foregroundStyle(Color.mutedStrong)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(item.value).font(.sofiaNumeral(40, .bold)).foregroundStyle(Color.textPrimary)
                            if let unit = item.unit {
                                Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if items.count < 3 { Color.clear.frame(maxWidth: .infinity) }
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 18)
        }
    }

    private func yourBest(_ s: TrackStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Your best here")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isPointToPoint ? "BEST RUN" : "BEST LAP")
                        .font(.system(size: 12, weight: .semibold)).kerning(0.9).foregroundStyle(Color(hex: 0x8A8A8A))
                    Text(RunFormat.time(s.best ?? 0)).font(.sofiaNumeral(52, .bold)).foregroundStyle(Color.textPrimary)
                    if let d = s.lastVisitDelta, abs(d) >= 0.005 {
                        Text("\(d < 0 ? "−" : "+")\(String(format: "%.2f", abs(d))) vs last visit")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(d < 0 ? Color(hex: 0x4CD964) : Color(hex: 0xFF6B5E))
                            .padding(.horizontal, 12).frame(height: 26)
                            .background((d < 0 ? Color(hex: 0x14301D) : Color(hex: 0x3A1512)), in: Capsule())
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    countRow("\(s.sessions)", s.sessions == 1 ? "session" : "sessions")
                    countRow("\(s.laps)", isPointToPoint ? (s.laps == 1 ? "run" : "runs") : (s.laps == 1 ? "lap" : "laps"))
                    if let last = s.lastVisit {
                        countRow(last.formatted(.dateTime.month(.abbreviated).day()), "last visit")
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func countRow(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.sofiaNumeral(22, .bold)).foregroundStyle(Color.textPrimary)
            Text(label).font(.system(size: 12)).foregroundStyle(Color.muted)
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Sessions here")
                Spacer()
                if sessions.count > 3 {
                    NavigationLink(value: TrackSessionsRoute(trackId: track.id)) {
                        Text("See all \(sessions.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accent)
                    }
                }
            }
            if sessions.isEmpty {
                Text("None yet. Drive here with recording on and sessions are matched automatically.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            ForEach(sessions.prefix(3)) { SessionLinkCard(session: $0, metric: metric) }
        }
    }

    // MARK: Conditions

    private func conditions(_ w: SessionManifest.WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Conditions now")
            HStack(spacing: 12) {
                let filled = UIImage(systemName: w.symbolName + ".fill") != nil ? w.symbolName + ".fill" : w.symbolName
                Image(systemName: filled).symbolRenderingMode(.multicolor).font(.system(size: 24))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(units.temp(fromC: w.temperatureC).rounded()))°")
                        .font(.sofiaNumeral(34, .bold)).foregroundStyle(Color.textPrimary)
                    Text(w.condition).font(.system(size: 12)).foregroundStyle(Color.muted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "wind").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.muted)
                    Text("\(Int(units.speed(fromMps: w.windMps).rounded())) \(units.speedUnit.lowercased()) \(w.windCompass)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.textPrimary)
                }
            }
            .padding(16)
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            WeatherAttributionRow()
        }
    }

    // MARK: Corners

    /// Corners with a real name ("The Corkscrew"), not just a number ("T4").
    private var namedCorners: [Track.Corner] {
        guard !current.isUserTrack else { return [] }
        return current.corners.filter { $0.name.range(of: #"^T\d+[A-Z]?$"#, options: .regularExpression) == nil }
    }

    private var cornersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Famous corners")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(namedCorners) { c in
                        ZStack(alignment: .topLeading) {
                            TrackShapeView(track: current, bestRun: nil, directory: nil,
                                           style: TrackShapeStyle(lineColor: Color(hex: 0x5A5A5E), lineWidth: 3,
                                                                  highlightCorner: c.n, padding: CGSize(width: 10, height: 10)))
                                .frame(width: 110, height: 120)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.top, 10)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(turnLabel(c).uppercased())
                                    .font(.system(size: 12, weight: .semibold)).kerning(0.9).foregroundStyle(Color.accent)
                                Text(c.name).font(.sofia(24, .bold)).foregroundStyle(Color.textPrimary)
                                    .frame(width: 120, alignment: .leading)
                            }
                            .padding(16)
                        }
                        .frame(width: 250, height: 150)
                        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// "T2" → "Turn 2", "T8–8A" → "Turns 8–8A"; no official number → driving order.
    private func turnLabel(_ c: Track.Corner) -> String {
        guard let t = c.officialTurn else { return "Turn \(c.n)" }
        let n = t.hasPrefix("T") ? String(t.dropFirst()) : t
        return (n.contains("–") || n.contains("-") ? "Turns " : "Turn ") + n
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.numeral(20, weight: .bold))
            .foregroundStyle(Color(hex: 0x8A8A8A))
            .padding(.top, 28)
            .padding(.bottom, 10)
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

/// A SessionCard that opens the session preview. Outside a List a plain
/// NavigationLink adds no chevron, so the card looks as it does in Sessions.
struct SessionLinkCard: View {
    let session: SessionManifest
    let metric: Bool

    var body: some View {
        NavigationLink(value: session.id) {
            SessionCard(session: session, metric: metric)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// "See all": every session on a track, newest first.
struct TrackSessionsList: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    let route: TrackSessionsRoute
    @State private var sessions: [SessionManifest] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(sessions) { SessionLinkCard(session: $0, metric: metric) }
            }
            .padding(16)
        }
        .background(Color.bgScreen)
        .navigationTitle(model.tracks.track(id: route.trackId)?.name ?? "Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.recording.sessionsVersion) {
            sessions = model.store.list().filter { $0.track?.id == route.trackId }.sorted { $0.startedAtUTC > $1.startedAtUTC }
        }
    }
}
