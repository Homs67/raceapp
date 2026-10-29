//
//  RecordingLiveActivityView.swift
//  raceAppWidgets
//
//  Lock Screen and Dynamic Island faces for an in-progress recording. Same
//  content as the in-app collapsed recorder: a pulsing record dot, the session
//  title, and the elapsed clock.
//
//  Type is condensed numerals with tabular digits, as in the app. The bundled
//  Sofia Sans Condensed statics are app-target resources, so the extension
//  uses the system compressed face instead of duplicating the TTFs into a
//  second bundle.
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Tokens (mirrors raceApp/Theme/Theme.swift)

extension Color {
    static let liveRecordRed = Color(red: 0xD9 / 255, green: 0x34 / 255, blue: 0x20 / 255) // toolbarRed
    static let liveAccent = Color(red: 0xDF / 255, green: 0x53 / 255, blue: 0x13 / 255)    // accent
    static let liveMuted = Color.white.opacity(0.45)
    static let liveMutedStrong = Color.white.opacity(0.6)
}

extension Font {
    /// Condensed numerals with tabular digits — the app's `.numeral()`.
    static func liveNumeral(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.compressed).monospacedDigit()
    }

    static func liveLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium)
    }
}

// MARK: - Shared pieces

private typealias State = RecordingActivityAttributes.ContentState

private func displayTitle(_ attributes: RecordingActivityAttributes, _ state: State) -> String {
    state.locationName ?? attributes.title
}

private func lapTimeText(_ seconds: Double) -> String {
    let m = Int(seconds) / 60
    let s = seconds - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}

/// The record dot. Red while recording, hollow while paused.
private struct RecordDot: View {
    var paused: Bool
    var size: CGFloat = 8

    var body: some View {
        Group {
            if paused {
                Circle()
                    .strokeBorder(Color.liveMutedStrong, lineWidth: max(1.5, size * 0.2))
            } else {
                Circle().fill(Color.liveRecordRed)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Elapsed clock. `Text(timerInterval:)` ticks on its own, so the app pushes
/// no updates for time passing; `pauseTime` freezes it where the user paused.
private struct ElapsedClock: View {
    var state: State
    var size: CGFloat

    var body: some View {
        Text(
            timerInterval: state.clockStart...Date(timeIntervalSinceNow: 60 * 60 * 24),
            pauseTime: state.pausedAt,
            countsDown: false
        )
        .font(.liveNumeral(size))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(state.isPaused ? Color.liveMutedStrong : Color.liveRecordRed)
    }
}

private struct LapLine: View {
    var state: State

    var body: some View {
        if let lapCount = state.lapCount {
            HStack(spacing: 6) {
                Text("LAP \(lapCount + 1)")
                    .font(.liveLabel())
                    .kerning(1)
                    .foregroundStyle(Color.liveMuted)
                    .fixedSize()
                if let last = state.lastLapSeconds {
                    Text(lapTimeText(last))
                        .font(.liveNumeral(13, .semibold))
                        .foregroundStyle(Color.liveMutedStrong)
                        .fixedSize()
                }
            }
        }
    }
}

// MARK: - Lock Screen / banner

struct RecordingLockScreenView: View {
    var context: ActivityViewContext<RecordingActivityAttributes>

    private var state: State { context.state }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    RecordDot(paused: state.isPaused)
                    Text(state.isPaused ? "PAUSED" : "RECORDING")
                        .font(.liveLabel())
                        .kerning(1.2)
                        .foregroundStyle(state.isPaused ? Color.liveMutedStrong : Color.liveRecordRed)
                        .fixedSize()
                }
                Text(displayTitle(context.attributes, state))
                    .font(.liveNumeral(22, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                LapLine(state: state)
            }
            Spacer(minLength: 8)
            ElapsedClock(state: state, size: 34)
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(Color.liveAccent)
    }
}

// MARK: - Widget

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(context: context)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecordDot(paused: state.isPaused)
                        Text(state.isPaused ? "PAUSED" : "REC")
                            .font(.liveLabel())
                            .kerning(1.2)
                            .foregroundStyle(state.isPaused ? Color.liveMutedStrong : Color.liveRecordRed)
                            .fixedSize()
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedClock(state: state, size: 20)
                        .frame(maxWidth: 76, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(displayTitle(context.attributes, state))
                            .font(.liveNumeral(20, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        LapLine(state: state)
                    }
                }
            } compactLeading: {
                RecordDot(paused: state.isPaused, size: 9)
            } compactTrailing: {
                ElapsedClock(state: state, size: 15)
                    .frame(maxWidth: 54)
            } minimal: {
                RecordDot(paused: state.isPaused, size: 9)
            }
            .keylineTint(state.isPaused ? Color.liveMutedStrong : Color.liveRecordRed)
        }
    }
}
