//
//  Achievements.swift
//  raceApp
//
//  Track achievements: one metal emblem per catalogued track, earned by
//  driving one complete timed lap there. Nothing is stored about earning one
//  — it is read off the sessions' cached runs, like the Tracks grid — except
//  which unlocks have already been announced with the full-screen pop-up.
//

import Foundation
import SwiftUI
import SessionKit

/// A track that has an emblem. Adding one is a line here plus the track's
/// bundled outline (tools/build_tracks.py).
struct AchievementEntry: Identifiable, Hashable {
    let trackId: String
    /// On the emblem's band and under the thumbnail.
    let shortName: String
    /// Enamel colour of the emblem face.
    let enamel: UInt32
    /// Borrow another track's outline (for test entries with no map of their own).
    var outlineTrackId: String? = nil
    /// Full name under the open emblem when there's no bundled track to name it.
    var fullName: String? = nil
    /// The emblem's outline; picked from the track id when not set.
    var shape: EmblemShape? = nil

    /// Shapes tracks are given: a stable pick per track, so an emblem keeps
    /// its shape from launch to launch.
    static let shapes: [EmblemShape] = [.pentagon, .circle, .hexagon]
    var emblemShape: EmblemShape {
        shape ?? Self.shapes[trackId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.shapes.count]
    }
    var id: String { trackId }
}

enum AchievementCatalog {
    /// California circuits first; more join as their outlines are bundled.
    static let all: [AchievementEntry] = [
        AchievementEntry(trackId: "laguna-seca", shortName: "Laguna Seca", enamel: 0x2FB4E8, shape: .circle),
        AchievementEntry(trackId: "big-willow", shortName: "Willow Springs", enamel: 0xDF5313, shape: .hexagon),
        AchievementEntry(trackId: "streets-of-willow", shortName: "Streets of Willow", enamel: 0x34C759, shape: .pentagon),
    ]

    /// TEST: shown as earned even without a lap there, so the emblem can be
    /// opened on a phone that hasn't driven the track. Real laps take over.
    static let previewUnlocked: [String: AchievementProgress] = [
        "big-willow": AchievementProgress(earnedAt: Date(timeIntervalSince1970: 1_792_684_800), bestLap: 104.39, laps: 1),
    ]
}

/// What a driver has done on one catalogued track.
struct AchievementProgress: Equatable {
    var earnedAt: Date
    var bestLap: TimeInterval
    var laps: Int
}

@MainActor @Observable
final class AchievementsModel {
    /// Unlocked tracks by id.
    private(set) var progress: [String: AchievementProgress] = [:]
    /// A fresh unlock waiting for its pop-up.
    var pending: AchievementEntry?

    private static let announcedKey = "announcedAchievements"

    func isUnlocked(_ entry: AchievementEntry) -> Bool { progress[entry.trackId] != nil }

    /// Re-read the sessions. Unlocks that haven't been announced become the
    /// pending pop-up — except on the very first run, when everything already
    /// earned is taken as known so old drives don't all pop up at once.
    func refresh(_ manifests: [SessionManifest]) {
        progress = Self.compute(manifests).merging(AchievementCatalog.previewUnlocked) { real, _ in real }
        let defaults = UserDefaults.standard
        let unlocked = Set(progress.keys)
        guard let stored = defaults.stringArray(forKey: Self.announcedKey) else {
            defaults.set(Array(unlocked), forKey: Self.announcedKey)
            return
        }
        let announced = Set(stored)
        if pending == nil, let fresh = AchievementCatalog.all.first(where: { unlocked.contains($0.trackId) && !announced.contains($0.trackId) }) {
            pending = fresh
        }
    }

    /// The pop-up was shown.
    func markAnnounced(_ entry: AchievementEntry) {
        let defaults = UserDefaults.standard
        var announced = Set(defaults.stringArray(forKey: Self.announcedKey) ?? [])
        announced.insert(entry.trackId)
        defaults.set(Array(announced), forKey: Self.announcedKey)
        if pending == entry { pending = nil }
    }

    /// One complete lap (or point-to-point run) on a track earns it; the
    /// earliest such session is when.
    static func compute(_ manifests: [SessionManifest]) -> [String: AchievementProgress] {
        let ids = Set(AchievementCatalog.all.map(\.trackId))
        var out: [String: AchievementProgress] = [:]
        for m in manifests {
            guard let ref = m.track, ids.contains(ref.id) else { continue }
            let laps = ref.runs.compactMap { run -> TimeInterval? in
                guard run.kind != .dnf, let end = run.end else { return nil }
                return end - run.start
            }
            guard let best = laps.min() else { continue }
            if var p = out[ref.id] {
                p.earnedAt = min(p.earnedAt, m.startedAtUTC)
                p.bestLap = min(p.bestLap, best)
                p.laps += laps.count
                out[ref.id] = p
            } else {
                out[ref.id] = AchievementProgress(earnedAt: m.startedAtUTC, bestLap: best, laps: laps.count)
            }
        }
        return out
    }
}
