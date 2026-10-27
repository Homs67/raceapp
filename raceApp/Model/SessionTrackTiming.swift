//
//  SessionTrackTiming.swift
//  raceApp
//
//  Keeps every session's track and runs current. Nobody picks a track before
//  driving: when a session ends (or a RaceBox drive is imported) its GPS is
//  timed against the nearby tracks and the one it actually ran on is kept.
//  When a track's gates are edited, every session on it is re-timed, and
//  unassigned sessions near it get a chance to match — so a course built after
//  the event still times that day's runs.
//

import Foundation
import SessionKit

enum SessionTrackTiming {

    /// GPS the timer runs on. RaceBox fixes when the logger owned position,
    /// phone fixes otherwise — both land in gps.lat/lon.
    nonisolated static func gps(in directory: URL) -> (lat: [ChannelSample], lon: [ChannelSample]) {
        (ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: directory),
         ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: directory))
    }

    /// Auto-assign a track if the session has none (or only an automatic one).
    /// Returns the updated manifest when something changed.
    nonisolated static func autoAssign(_ manifest: SessionManifest, store: SessionStore,
                                       candidates: [CourseMatcher.Candidate],
                                       names: [String: String], updated: [String: Date]) -> SessionManifest? {
        guard SessionManifest.TrackRef.autoMatchMayReplace(manifest.track) else { return nil }
        let (lat, lon) = gps(in: store.directory(for: manifest.id))
        guard !lat.isEmpty else { return nil }
        let match = CourseMatcher.best(candidates, lat: lat, lon: lon, sessionDate: manifest.startedAtUTC)
        var m = manifest
        if let match, let layout = candidates.first(where: { $0.id == match.id })?.layout {
            m.track = .init(id: match.id, nameSnapshot: names[match.id] ?? match.id, assignedBy: .auto,
                            layout: layout, timedAgainst: updated[match.id], runs: match.runs)
        } else if manifest.track != nil {
            m.track = nil   // an automatic match that no longer fits (gates moved away)
        }
        guard m.track != manifest.track else { return nil }
        try? store.save(m)
        return m
    }

    /// Re-time a session against the track it is assigned to.
    nonisolated static func retime(_ manifest: SessionManifest, store: SessionStore,
                                   layout: CourseLayout?, name: String, updatedAt: Date?) -> SessionManifest? {
        guard var ref = manifest.track else { return nil }
        let (lat, lon) = gps(in: store.directory(for: manifest.id))
        ref.nameSnapshot = name
        ref.layout = layout
        ref.timedAgainst = updatedAt
        ref.runs = layout.map { CourseTiming.runs(lat: lat, lon: lon, layout: $0) } ?? []
        var m = manifest
        m.track = ref
        guard m.track != manifest.track else { return nil }
        try? store.save(m)
        return m
    }
}

@MainActor
extension AppModel {

    private var trackTables: (candidates: [CourseMatcher.Candidate], names: [String: String], updated: [String: Date]) {
        let all = tracks.all
        return (tracks.matchCandidates,
                Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                Dictionary(all.compactMap { t in t.updatedAt.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a }))
    }

    /// After a recording or import: find the track, then hand the final
    /// manifest to whatever comes next (the iCloud mirror).
    func assignTrack(to ids: [UUID], then next: (@MainActor (SessionManifest) -> Void)? = nil) {
        let store = self.store
        let tables = trackTables
        Task { [weak self] in
            let results: [SessionManifest] = await Task.detached(priority: .utility) {
                ids.compactMap { id -> SessionManifest? in
                    guard let m = try? store.manifest(for: id) else { return nil }
                    return SessionTrackTiming.autoAssign(m, store: store, candidates: tables.candidates,
                                                         names: tables.names, updated: tables.updated) ?? m
                }
            }.value
            self?.recording.noteSessionsChanged()
            if let next { results.forEach(next) }
        }
    }

    /// A track was created or edited: re-time its sessions, and let sessions
    /// with no manual choice near it match afresh.
    func trackDidChange(_ track: Track) {
        let store = self.store
        let tables = trackTables
        let layout = track.layout
        let id = track.id, name = track.name, updatedAt = track.updatedAt
        Task { [weak self] in
            let changed: Int = await Task.detached(priority: .utility) {
                var count = 0
                for m in store.list() {
                    if m.track?.id == id, m.track?.assignedBy == .manual {
                        if SessionTrackTiming.retime(m, store: store, layout: layout, name: name, updatedAt: updatedAt) != nil { count += 1 }
                    } else if SessionTrackTiming.autoAssign(m, store: store, candidates: tables.candidates,
                                                            names: tables.names, updated: tables.updated) != nil {
                        count += 1
                    }
                }
                return count
            }.value
            if changed > 0 { self?.recording.noteSessionsChanged() }
        }
    }

    /// Re-time a session whose runs were computed against an older version
    /// of its track (the track was edited while this session was elsewhere).
    func retimeIfStale(_ manifest: SessionManifest) {
        guard let ref = manifest.track, !ref.id.isEmpty, let track = tracks.track(id: ref.id),
              ref.timedAgainst != track.updatedAt || ref.layout != track.layout else { return }
        let store = self.store
        let layout = track.layout, name = track.name, updatedAt = track.updatedAt
        Task { [weak self] in
            let changed = await Task.detached(priority: .userInitiated) {
                SessionTrackTiming.retime(manifest, store: store, layout: layout, name: name, updatedAt: updatedAt)
            }.value
            if changed != nil { self?.recording.noteSessionsChanged() }
        }
    }

    /// Back to automatic: forget a manual choice and match afresh.
    func autoDetectTrack(for sessionId: UUID) {
        guard var m = try? store.manifest(for: sessionId) else { return }
        m.track = nil
        try? store.save(m)
        assignTrack(to: [sessionId])
    }

    /// The user picked a track (or "none") for a session in review.
    func setTrack(_ track: Track?, for sessionId: UUID) {
        guard var m = try? store.manifest(for: sessionId) else { return }
        if let track {
            m.track = .init(id: track.id, nameSnapshot: track.name, assignedBy: .manual,
                            layout: nil, timedAgainst: nil, runs: [])
            _ = SessionTrackTiming.retime(m, store: store, layout: track.layout,
                                          name: track.name, updatedAt: track.updatedAt)
        } else {
            // "None" is a manual choice too: keep auto-matching away from it.
            m.track = .init(id: "", nameSnapshot: "", assignedBy: .manual, layout: nil, timedAgainst: nil, runs: [])
            try? store.save(m)
        }
        recording.noteSessionsChanged()
    }
}
