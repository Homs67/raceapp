//
//  RecordingToolbar.swift
//  raceApp
//
//  Figma 125:4672 — top-edge toolbar revealed by tapping the dashboard while
//  recording: red dot + HH:MM:SS, page pills, STOP. Nothing else lives here;
//  the camera and collapse controls moved to the camera widget and to a
//  swipe-down on this bar respectively.
//

import SwiftUI

@MainActor @Observable
final class ToolbarVisibility {
    private(set) var visible = false
    private var hideTask: Task<Void, Never>?
    /// The pager's tap recogniser fires once as the full-screen cover lands;
    /// ignore toggles until the view has been up for a moment.
    private var armedAt = Date()

    nonisolated deinit {}   // see DashboardStore

    func show(for duration: Duration = .seconds(4)) {
        withAnimation(.easeOut(duration: 0.2)) { visible = true }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        withAnimation(.easeOut(duration: 0.2)) { visible = false }
    }

    func arm() { armedAt = Date() }

    func toggle() {
        guard Date().timeIntervalSince(armedAt) > 1 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        visible ? hide() : show()
    }
    /// Any interaction restarts the auto-hide clock.
    func touch() { if visible { show() } }
}

struct RecordingToolbar: View {
    let elapsed: TimeInterval
    let pageIndex: Int
    let pageCount: Int
    let onStop: () -> Void
    let onInteract: () -> Void
    let onCollapse: () -> Void
    /// Landscape: one row along the top edge (Figma). Portrait: rises from
    /// the bottom, pills centred under the timer / STOP row.
    var edge: Edge = .top
    var safeBottom: CGFloat = 0

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: edge == .top ? .top : .bottom) {
            // Opaque under the controls, then fades — the widget beneath
            // must not show through the timer.
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.45),
                                   .init(color: .black.opacity(0), location: 1)],
                           startPoint: edge == .top ? .top : .bottom,
                           endPoint: edge == .top ? .bottom : .top)
                .frame(height: 240)
                .allowsHitTesting(false)

            if edge == .top {
                HStack(spacing: 0) {
                    timer
                    Spacer(minLength: 16)
                    pager
                    Spacer(minLength: 16)
                    stopButton
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
            } else {
                VStack(spacing: 20) {
                    HStack(spacing: 0) {
                        timer
                        Spacer(minLength: 16)
                        stopButton
                    }
                    pager
                }
                .padding(.horizontal, 32)
                .padding(.bottom, max(safeBottom, 16) + 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: edge == .top ? .top : .bottom)
        .contentShape(Rectangle())
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    onInteract()
                    if value.translation.height > 0 { dragOffset = value.translation.height }
                }
                .onEnded { value in
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 220 {
                        onCollapse()
                    }
                }
        )
    }

    private var timer: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.toolbarRed.opacity(0.35)).frame(width: 20, height: 20)
                Circle().fill(Color.toolbarRed).frame(width: 8, height: 8)
            }
            Text(SessionElapsedFormat.formatLong(elapsed))
                .font(.sofiaNumeral(24, .bold))
                .kerning(1)
                .foregroundStyle(Color.toolbarRed)
        }
        .accessibilityLabel("Recording \(SessionElapsedFormat.formatLong(elapsed))")
    }

    private var pager: some View {
        HStack(spacing: 10) {
            ForEach(0..<max(1, pageCount), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i == pageIndex ? Color.white : Color.widgetBorder)
                    .frame(width: 18, height: 12)
                    .overlay {
                        if i == pageIndex {
                            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 2)
                        }
                    }
            }
        }
        .accessibilityLabel("Dashboard \(pageIndex + 1) of \(pageCount)")
    }

    private var stopButton: some View {
        Button {
            onStop()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(.black).frame(width: 12, height: 12)
                Text("STOP")
                    .font(.sofia(24, .bold))
                    .kerning(1)
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(height: 56)
            .background(Color.toolbarRed, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Stop Recording")
    }
}
