//
//  RecordingToolbar.swift
//  raceApp
//
//  Figma 06 · Collapsed recorder, mock ① (348:4182) and ④ (350:4182).
//
//  The recording dashboard carries two separate pieces of chrome:
//
//  • `RecordingTopBar` is always on screen — elapsed, which dashboard you are
//    on, and the way out. It never hides, so you can always read the clock and
//    always leave.
//  • `RecordingControlBar` holds pause and stop and is the only thing
//    `ToolbarVisibility` governs. Tapping the dashboard drops it so the
//    widgets run edge to edge; tapping again brings it back.
//
//  Both orientations put the controls along the bottom. In landscape that bar
//  is an overlay rather than layout, because 402 pt of height cannot give a
//  row up — it covers the bottom widget row only while it is up.
//

import SwiftUI

@MainActor @Observable
final class ToolbarVisibility {
    /// Controls are on screen when the dashboard opens, and tapping the
    /// dashboard puts them away so the widgets run edge to edge. They do not
    /// time out: pause and stop belong where you last left them, and a bar
    /// that vanishes on its own is one you have to hunt for at the end of a
    /// session.
    private(set) var visible = true
    /// The pager's tap recogniser fires once as the full-screen cover lands;
    /// ignore toggles until the view has been up for a moment.
    private var armedAt = Date()

    nonisolated deinit {}   // see DashboardStore

    func show() { withAnimation(.easeOut(duration: 0.2)) { visible = true } }

    func hide() { withAnimation(.easeOut(duration: 0.2)) { visible = false } }

    func arm() { armedAt = Date() }

    func toggle() {
        guard Date().timeIntervalSince(armedAt) > 1 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        visible ? hide() : show()
    }
}

// MARK: - Top bar

/// Elapsed, pagination and the way out. Permanent: hiding the clock while
/// recording, or hiding the exit, is how a session gets lost.
struct RecordingTopBar: View {
    /// Pill height plus the padding above and below it. The grid is inset by
    /// this while recording — the bar never hides, so a widget placed under it
    /// would simply be unreadable for the whole session.
    static func height(safeTop: CGFloat) -> CGFloat {
        max(safeTop, 12) + 8 + 30 + 10
    }

    let elapsed: TimeInterval
    /// The pill must not keep saying "recording" in red while it is not.
    var isPaused: Bool = false
    let pageIndex: Int
    let pageCount: Int
    /// Leave nil until there is somewhere to collapse to — a chevron that
    /// dismisses the dashboard with no way back is a trap, so the button is
    /// simply absent rather than inert.
    var onCollapse: (() -> Void)?
    var safeTop: CGFloat = 0
    /// In landscape the Dynamic Island sits on one of the long edges, so the
    /// pill and the chevron have to clear it the way the grid does.
    var safeLeading: CGFloat = 0
    var safeTrailing: CGFloat = 0

    var body: some View {
        // The pill and the chevron are different widths, so an HStack would
        // centre the pager between them rather than on the screen. Centre it
        // against the full width and hang the other two off the edges.
        ZStack {
            pager
            HStack(spacing: 12) {
                elapsedPill
                Spacer(minLength: 0)
                collapseButton
            }
        }
        .padding(.leading, max(safeLeading, 20))
        .padding(.trailing, max(safeTrailing, 20))
        .padding(.top, max(safeTop, 12) + 8)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var elapsedPill: some View {
        HStack(spacing: 8) {
            if isPaused {
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(.white.opacity(0.6)).frame(width: 2.5, height: 9)
                    }
                }
            } else {
                Circle()
                    .fill(Color.toolbarRed)
                    .frame(width: 8, height: 8)
            }
            Text(SessionElapsedFormat.formatLong(elapsed))
                .font(.sofiaNumeral(18, .bold))
                .kerning(0.5)
                .foregroundStyle(isPaused ? .white.opacity(0.7) : Color.toolbarRed)
                .monospacedDigit()
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(isPaused ? AnyShapeStyle(.white.opacity(0.12))
                             : AnyShapeStyle(Color.toolbarRed.opacity(0.22)),
                    in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused
            ? "Paused at \(SessionElapsedFormat.formatLong(elapsed))"
            : "Recording \(SessionElapsedFormat.formatLong(elapsed))")
    }

    private var pager: some View {
        HStack(spacing: 10) {
            ForEach(0..<max(1, pageCount), id: \.self) { i in
                Circle()
                    .fill(i == pageIndex ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dashboard \(pageIndex + 1) of \(pageCount)")
    }

    @ViewBuilder
    private var collapseButton: some View {
        if let onCollapse {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.widgetBorder.opacity(0.85), in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Hide dashboard, keep recording")
        } else {
            Color.clear.frame(width: 36, height: 36)
        }
    }
}

// MARK: - Control bar

/// Pause and stop, over a fade so neither ever sits on a widget value.
/// Pause is the frequent, safe action and carries the weight; stop is labelled
/// because two near-identical circles is how a session gets ended by mistake.
struct RecordingControlBar: View {
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onStop: () -> Void
    /// Landscape has far less height to give up.
    var compact: Bool = false
    var safeBottom: CGFloat = 0

    private var controlHeight: CGFloat { compact ? 48 : 56 }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.82), location: 0.5),
                                   .init(color: .black.opacity(0.95), location: 1)],
                           startPoint: .top,
                           endPoint: .bottom)
                .frame(height: compact ? 150 : 190)
                .allowsHitTesting(false)

            HStack(spacing: 16) {
                pauseButton
                stopButton
            }
            .padding(.bottom, max(safeBottom, 16) + 8)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
    }

    private var pauseButton: some View {
        Button(action: onPauseResume) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: controlHeight * 0.36, weight: .black))
                .foregroundStyle(.black)
                .frame(width: controlHeight, height: controlHeight)
                .background(.white, in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white)
                    .frame(width: controlHeight * 0.24, height: controlHeight * 0.24)
                Text("Stop")
                    .font(.system(size: compact ? 16 : 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.leading, controlHeight * 0.38)
            .padding(.trailing, controlHeight * 0.42)
            .frame(height: controlHeight)
            .background(Color.toolbarRed, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Stop recording")
    }
}
