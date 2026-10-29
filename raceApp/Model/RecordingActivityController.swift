//
//  RecordingActivityController.swift
//  raceApp
//
//  Owns the Lock Screen / Dynamic Island Live Activity for the running
//  session. The elapsed clock is a `Text(timerInterval:)` inside the widget,
//  so this pushes nothing for time passing — only when the place name, the
//  lap, or the pause state changes, and then at most once every few seconds.
//
//  Everything is best-effort: with Live Activities switched off, or when
//  ActivityKit refuses, recording carries on and nothing is reported.
//

import ActivityKit
import Foundation

@MainActor
final class RecordingActivityController {

    static let shared = RecordingActivityController()

    /// What the activity shows beyond the clock, polled while recording.
    struct Sample: Equatable {
        var locationName: String?
        var lapCount: Int?
        var lastLapSeconds: Double?
    }

    /// Lap / place changes are not worth a process hop each time they tick.
    private let minimumPushInterval: TimeInterval = 8
    private let pollInterval: Duration = .seconds(5)

    private var activity: Activity<RecordingActivityAttributes>?
    /// What the activity should show right now.
    private var desired = RecordingActivityAttributes.ContentState(clockStart: Date())
    /// What ActivityKit has actually been handed.
    private var pushedState: RecordingActivityAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var trailingPush: Task<Void, Never>?

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: - Lifecycle

    /// Start the activity for a session that just began. `sample` is polled on
    /// the main actor while the activity lives; returning nil ends it.
    func start(title: String, startedAt: Date, sample: @escaping @MainActor () -> Sample?) {
        guard enabled, activity == nil else { return }
        desired = RecordingActivityAttributes.ContentState(clockStart: startedAt)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(title: title, startedAt: startedAt),
                content: ActivityContent(state: desired, staleDate: nil),
                pushType: nil
            )
            pushedState = desired
            lastPush = Date()
        } catch {
            activity = nil
            return
        }
        startPolling(sample)
    }

    /// Reflect a user pause / resume straight away — the frozen clock is the
    /// whole point, so this one is never throttled.
    func setPaused(_ paused: Bool) {
        guard activity != nil, paused != desired.isPaused else { return }
        if paused {
            desired.pausedAt = Date()
        } else if let pausedAt = desired.pausedAt {
            // Keep the clock reading recorded time, not wall time.
            desired.clockStart = desired.clockStart.addingTimeInterval(Date().timeIntervalSince(pausedAt))
            desired.pausedAt = nil
        }
        push(force: true)
    }

    func end() {
        pollTask?.cancel()
        pollTask = nil
        trailingPush?.cancel()
        trailingPush = nil
        guard let activity else { return }
        self.activity = nil
        pushedState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// An activity outlives a crash or a force-quit mid-session. Clear anything
    /// left over at launch so the Lock Screen never shows a dead recording.
    func endOrphanedActivities() {
        Task {
            for orphan in Activity<RecordingActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Updates

    private func startPolling(_ sample: @escaping @MainActor () -> Sample?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.pollInterval ?? .seconds(5)
                try? await Task.sleep(for: interval)
                guard let self, self.activity != nil else { return }
                guard let next = sample() else { return self.end() }
                self.desired.locationName = next.locationName
                self.desired.lapCount = next.lapCount
                self.desired.lastLapSeconds = next.lastLapSeconds
                self.push(force: false)
            }
        }
    }

    private func push(force: Bool) {
        guard let activity, desired != pushedState else { return }
        let since = Date().timeIntervalSince(lastPush)
        if !force, since < minimumPushInterval {
            scheduleTrailingPush(after: minimumPushInterval - since)
            return
        }
        trailingPush?.cancel()
        trailingPush = nil
        pushedState = desired
        lastPush = Date()
        let content = ActivityContent(state: desired, staleDate: nil)
        Task { await activity.update(content) }
    }

    /// Coalesce everything that arrives inside the throttle window into one
    /// push at the end of it, so no change is simply dropped.
    private func scheduleTrailingPush(after delay: TimeInterval) {
        guard trailingPush == nil else { return }
        trailingPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.activity != nil else { return }
            self.trailingPush = nil
            self.push(force: true)
        }
    }
}
