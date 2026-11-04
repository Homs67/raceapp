//
//  SessionPreviewBar.swift
//  raceApp
//
//  Figma 06 · Collapsed recorder, mock ③ (349:4231).
//
//  What a running session looks like once the dashboard has been put away:
//  still recording, how long for, which session, and the three things you can
//  do about it. Sits above the tab bar on every tab.
//
//  The order is deliberate. Pause is white because it is the one you will
//  actually press between runs; stop is grey rather than red because it is a
//  thumb's width from the tab bar and this is the one surface you see while
//  not looking at the app; open is the quiet glass button.
//

import SwiftUI

extension View {
    /// Hang the session bar above the tab bar on one tab's content.
    ///
    /// Applied per tab rather than once to the `TabView`: a `safeAreaInset` on
    /// the TabView itself lands *below* the tab bar, and the bar's height
    /// differs between OS versions, so no hard-coded offset is right. Insetting
    /// the tab's own content also stops lists scrolling under the bar.
    func sessionPreviewBar(_ model: AppModel) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            SessionPreviewBarHost(model: model)
        }
    }
}

private struct SessionPreviewBarHost: View {
    let model: AppModel

    var body: some View {
        if model.recording.isRecording, !model.isDashboardPresented {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SessionPreviewBar(
                    elapsed: model.recording.elapsed(asOf: context.date),
                    isPaused: model.recording.isPaused,
                    title: title,
                    onOpen: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.isDashboardPresented = true
                    },
                    onPauseResume: {
                        Task {
                            if model.recording.isPaused {
                                await model.recording.resume()
                            } else {
                                await model.recording.pause()
                            }
                        }
                    },
                    onStop: { model.stopRecording() })
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Where the session started, else the track being timed against, else a
    /// plain label — never empty, since the name is how you tell two phones
    /// recording two cars apart.
    ///
    /// Location comes first on purpose: the track is only ever the *nearest*
    /// one, so a drive that starts on your own street was being labelled with
    /// a circuit a few miles away.
    private var title: String {
        model.recording.liveLocationName ?? model.metrics.track?.name ?? "Session"
    }
}

struct SessionPreviewBar: View {
    let elapsed: TimeInterval
    let isPaused: Bool
    let title: String
    let onOpen: () -> Void
    let onPauseResume: () -> Void
    let onStop: () -> Void

    private var clock: String {
        elapsed < 3600 ? SessionElapsedFormat.format(elapsed)
                       : SessionElapsedFormat.formatLong(elapsed)
    }

    var body: some View {
        HStack(spacing: 10) {
            indicator
            Text(clock)
                .font(.sofiaNumeral(21, .bold))
                .monospacedDigit()
                .foregroundStyle(isPaused ? .white.opacity(0.6) : .white)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 20)
            Text(isPaused ? "\(title) · Paused" : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isPaused ? 0.62 : 0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            pauseButton
            stopButton
            openButton
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 52)
        .background { glass }
        // Anywhere that is not a button brings the dashboard back.
        .contentShape(Capsule())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
    }

    /// Liquid Glass where the OS has it. Below iOS 26 this falls back to the
    /// tinted material it used before: the list scrolls past underneath, and a
    /// flat translucent fill let card text read straight through the bar.
    @ViewBuilder
    private var glass: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(Color.barGlass.opacity(0.5))
                .glassEffect(.regular.tint(Color.barGlass.opacity(0.5)), in: .capsule)
        } else {
            Capsule()
                .fill(Color.barGlass)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if isPaused {
            HStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.5)).frame(width: 3, height: 11)
                }
            }
            .frame(width: 14)
        } else {
            ZStack {
                Circle().fill(Color.toolbarRed.opacity(0.25)).frame(width: 14, height: 14)
                Circle().fill(Color.toolbarRed).frame(width: 7, height: 7)
            }
        }
    }

    private var pauseButton: some View {
        Button(action: onPauseResume) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(.white, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white)
                .frame(width: 10, height: 10)
                .frame(width: 32, height: 32)
                .background(Color.barStopGrey, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Stop recording")
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Image(systemName: "arrow.down.left.and.arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Open dashboard")
    }
}
