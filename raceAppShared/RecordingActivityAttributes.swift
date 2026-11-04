//
//  RecordingActivityAttributes.swift
//  raceApp + raceAppWidgets (shared)
//
//  The Live Activity contract for an in-progress recording. Shared by both
//  targets, so it stays free of anything app-only — no Theme, no SessionKit.
//
//  The elapsed clock is NOT pushed: `clockStart` lets the widget run its own
//  `Text(timerInterval:)`, which ticks on the Lock Screen and in the Dynamic
//  Island without the app waking up. Updates therefore only happen when
//  something a timer cannot derive changes (pause, place name, a lap).
//

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {

    /// Title known at START: the nearest track's name, else "Session". A
    /// reverse-geocoded street name lands later and overrides it from
    /// `ContentState.locationName` — same precedence as the in-app recorder bar.
    let title: String
    /// Wall-clock start of the session, for the "since" line.
    let startedAt: Date

    struct ContentState: Codable, Hashable {
        /// Reference date the running clock counts up from. Shifted forward by
        /// however long the session has spent paused, so the clock always reads
        /// recorded time rather than wall time.
        var clockStart: Date
        /// Non-nil while paused; the clock freezes at this instant.
        var pausedAt: Date?
        /// Reverse-geocoded place name, once it resolves.
        var locationName: String?
        /// Completed laps — nil when no track is known for this session.
        var lapCount: Int?
        /// Last completed lap, seconds.
        var lastLapSeconds: Double?

        var isPaused: Bool { pausedAt != nil }
        /// Recorded time at the moment this state was pushed.
        var elapsed: TimeInterval { (pausedAt ?? Date()).timeIntervalSince(clockStart) }
    }
}
