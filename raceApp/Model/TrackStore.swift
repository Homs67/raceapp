//
//  TrackStore.swift
//  raceApp
//
//  The track library: bundled circuits plus everything made in the app.
//  User tracks are JSON files in <AppSupport>/LiveData/tracks/. Editing a
//  bundled track saves a user copy under the same id, which shadows it.
//

import Foundation
import CoreLocation
import SessionKit

@MainActor @Observable
final class TrackStore {

    private(set) var userTracks: [Track] = []
    /// Bumped on every save/delete so views and the session re-timer react.
    private(set) var version = 0

    private let directory: URL

    init(directory: URL = TrackStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveData/tracks", isDirectory: true)
    }

    /// User tracks newest first, then bundled ones not shadowed by an edit.
    var all: [Track] {
        let user = userTracks.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        let shadowed = Set(user.map(\.id))
        return user + TrackDatabase.all.filter { !shadowed.contains($0.id) }
    }

    func track(id: String) -> Track? {
        userTracks.first { $0.id == id } ?? TrackDatabase.track(id: id)
    }

    func save(_ track: Track) {
        var t = track
        t.isUser = true
        t.updatedAt = Date()
        if t.createdAt == nil { t.createdAt = t.updatedAt }
        t.syncLegacyGate()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(t) {
            try? data.write(to: file(for: t.id), options: .atomic)
        }
        if let i = userTracks.firstIndex(where: { $0.id == t.id }) { userTracks[i] = t } else { userTracks.append(t) }
        version += 1
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: file(for: id))
        userTracks.removeAll { $0.id == id }
        version += 1
    }

    /// Nearest track with timing gates whose anchor is within `maxMeters`.
    func nearest(lat: Double, lon: Double, maxMeters: Double = 2000) -> Track? {
        let mLon = 111_320.0 * cos(lat * .pi / 180)
        var best: (Track, Double)?
        for t in all where t.layout != nil {
            guard let a = t.anchor else { continue }
            let dx = (a.longitude - lon) * mLon, dy = (a.latitude - lat) * 110_540
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= maxMeters, d < (best?.1 ?? .infinity) { best = (t, d) }
        }
        return best?.0
    }

    /// Candidates for the post-drive matcher.
    var matchCandidates: [CourseMatcher.Candidate] {
        all.compactMap { t in t.layout.map { CourseMatcher.Candidate(id: t.id, layout: $0, createdAt: t.createdAt) } }
    }

    private func file(for id: String) -> URL {
        directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        userTracks = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Track.self, from: $0) }
        }
    }
}
