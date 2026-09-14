//
//  DashboardPagerView.swift
//  raceApp
//
//  The recording dashboard: pages of widget grids, one live snapshot per
//  10 Hz tick, a tap-to-reveal toolbar while recording, and edit mode (a
//  single grid outside the pager, so page swipes never fight a drag).
//

import SwiftUI
import SessionKit

struct DashboardPagerView: View {

    enum Mode {
        case recording
        case preview(dashboardId: UUID, startEditing: Bool, onClose: () -> Void)

        var isRecording: Bool { if case .recording = self { return true } else { return false } }
    }

    let mode: Mode

    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    @State private var feed = DashboardLiveFeed()
    @State private var edit: DashboardEditController?
    @State private var toolbar = ToolbarVisibility()
    @State private var previewSelection: UUID?
    @State private var renaming = false
    @State private var draftName = ""
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if mode.isRecording {
                stage
            } else {
                // Native bar (glass on iOS 26): Close / Edit while previewing,
                // name / + Add / Done while editing.
                NavigationStack {
                    stage
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { navigationItems }
                        .alert("Dashboard name", isPresented: $renaming) {
                            TextField("Name", text: $draftName)
                            Button("Save") { edit?.rename(draftName) }
                            Button("Cancel", role: .cancel) {}
                        }
                }
                .tint(Color.accent)
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .sheet(item: Binding(get: { edit?.sheet }, set: { edit?.sheet = $0 })) { sheet in
            if let edit {
                switch sheet {
                case .options(let id): WidgetOptionsSheet(edit: edit, placementId: id)
                case .library(let index): WidgetLibrarySheet(edit: edit, mode: .insert(index))
                case .fill(let id): WidgetLibrarySheet(edit: edit, mode: .replace(id))
                }
            }
        }
        .onAppear(perform: configureForMode)
        .onChange(of: model.recording.isRecording) { _, recording in
            // A session starting underneath an editor saves and exits it.
            if recording, edit != nil { finishEditing() }
        }
    }

    /// The dashboard itself. The outer reader sees the real safe area (notch,
    /// home indicator, nav bar); the stack below ignores it once so every
    /// page is laid out at the exact screen size and gets the insets by value.
    private var stage: some View {
        @Bindable var store = model.dashboards
        return GeometryReader { outer in
            let safe = outer.safeAreaInsets
            // The screen itself, not the reader plus insets: with the home
            // indicator hidden the reader can come back short at the bottom.
            let fullSize = UIScreen.main.bounds.size
            // Under a nav bar (preview / edit) the grid is still laid out for
            // the bare screen — the device insets, not the bar's — and the
            // whole thing is zoomed out to clear the bar, like Home Screen
            // jiggle mode. Nothing reflows; Done zooms it back.
            let gridSafe = DeviceSafeArea.gridInsets(fallback: safe)
            let zoom = mode.isRecording ? 1 : Self.zoom(fullSize: fullSize, barTop: safe.top,
                                                          gridSafe: gridSafe, landscape: verticalSizeClass == .compact)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let track = model.metrics.track ?? previewTrack
                // Editing or previewing without a session: show plausible
                // values so the layout reads, not a wall of dashes.
                let live = mode.isRecording
                    ? feed.tick(model: model, now: uptimeNow(), date: context.date, metric: metric)
                    : LiveSnapshot.demo(track: track)
                let units = UnitsFormatter(metric: metric)
                let landscape = verticalSizeClass == .compact

                ZStack(alignment: .top) {
                    Color.black

                    Group {
                        if let edit {
                            DashboardGridView(dashboard: edit.working, live: live, track: track, units: units,
                                              edit: edit, size: fullSize, safeArea: gridSafe, edgeToEdge: false)
                        } else {
                            // SwiftUI paging rather than TabView: the UIKit page
                            // host insets and re-centres its pages by the safe
                            // area, which no combination of ignoresSafeArea
                            // undid. A paging ScrollView lays the pages out
                            // exactly where they're told.
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(store.dashboards) { dashboard in
                                        DashboardGridView(dashboard: dashboard, live: live, track: track, units: units,
                                                          onTap: { if mode.isRecording { toolbar.toggle() } },
                                                          size: fullSize, safeArea: gridSafe,
                                                          edgeToEdge: mode.isRecording)
                                            .id(dashboard.id)
                                            .onLongPressGesture(minimumDuration: 0.5) {
                                                guard !model.recording.isRecording else { return }
                                                beginEditing(dashboard)
                                            }
                                    }
                                }
                                .scrollTargetLayout()
                            }
                            .scrollTargetBehavior(.paging)
                            .scrollPosition(id: pageSelection)
                            .scrollIndicators(.hidden)
                            .contentMargins(0)
                            .ignoresSafeArea()
                        }
                    }
                    .frame(width: fullSize.width, height: fullSize.height)
                    .scaleEffect(zoom, anchor: .bottom)
                    .animation(.snappy(duration: 0.25), value: zoom)

                    if mode.isRecording, edit == nil {
                        RecordingIslandDot(safe: gridSafe, size: fullSize, landscape: landscape)
                    }

                    VStack(spacing: 6) {
                        healthPill
                        if let rejection = edit?.lastRejection {
                            pill(rejection, icon: "xmark.octagon.fill", color: Color.toolbarRed)
                        }
                    }
                    .padding(.top, safe.top)

                    if mode.isRecording, edit == nil, toolbar.visible {
                        RecordingToolbar(
                            elapsed: live.elapsed,
                            pageIndex: store.selectedIndex,
                            pageCount: store.dashboards.count,
                            onStop: { model.stopRecording() },
                            onInteract: { toolbar.touch() },
                            edge: landscape ? .top : .bottom,
                            safeBottom: safe.bottom)
                        .frame(maxHeight: .infinity, alignment: landscape ? .top : .bottom)
                        .transition(.move(edge: landscape ? .top : .bottom).combined(with: .opacity))
                    }
                }
                // Explicit full-screen frame and position: a child that merely
                // ignores the safe area gets centred on the reader's inset
                // frame (≈10 pt too high in landscape), so place it by hand.
                .ignoresSafeArea()
                .frame(width: fullSize.width, height: fullSize.height)
                .position(x: fullSize.width / 2 - safe.leading, y: fullSize.height / 2 - safe.top)
            }
        }
    }

    /// Scale (anchored at the screen bottom) that brings the grid's top edge —
    /// not the frame's — to just under the nav bar, so the zoom-out is only as
    /// much as the bar needs.
    private static func zoom(fullSize: CGSize, barTop: CGFloat, gridSafe: EdgeInsets, landscape: Bool) -> CGFloat {
        let gridTop = GridGeometry(available: fullSize, grid: .base, landscape: landscape, safe: gridSafe).bounds.minY
        // Same in preview and edit, and enough for edit mode's remove badges
        // (which hang ~17 pt above the grid) to clear the bar.
        let gap: CGFloat = 24
        let z = (fullSize.height - barTop - gap) / max(1, fullSize.height - gridTop)
        return min(1, max(0.5, z))
    }

    @ToolbarContentBuilder
    private var navigationItems: some ToolbarContent {
        if let edit {
            ToolbarItem(placement: .principal) {
                Button {
                    draftName = edit.working.name
                    renaming = true
                } label: {
                    HStack(spacing: 6) {
                        Text(edit.working.name).font(.sofia(20, .bold)).foregroundStyle(.white)
                        Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedStrong)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { edit.presentLibraryAppending() } label: { Label("Add", systemImage: "plus") }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: finishEditing).font(.sofia(18, .bold))
            }
        } else if case .preview(_, _, let onClose) = mode {
            ToolbarItem(placement: .principal) {
                Text(previewDashboard?.name ?? "").font(.sofia(20, .bold)).foregroundStyle(.white)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onClose)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { if let d = previewDashboard { beginEditing(d) } }
            }
        }
    }

    // MARK: - Pages

    /// The page currently shown in the Settings preview.
    private var previewDashboard: Dashboard? {
        previewSelection.flatMap { model.dashboards.dashboard(id: $0) }
    }

    private var pageSelection: Binding<UUID?> {
        switch mode {
        case .recording:
            return Binding(get: { model.dashboards.selectedId },
                           set: { if let id = $0 { model.dashboards.selectedId = id } })
        case .preview:
            return $previewSelection
        }
    }

    /// Preview (Settings) has no session, so give the lap map a track to draw.
    private var previewTrack: Track? {
        TrackDatabase.track(id: "big-willow") ?? TrackDatabase.all.first
    }

    private func configureForMode() {
        toolbar.arm()
        switch mode {
        case .recording:
            #if DEBUG
            if let i = CommandLine.arguments.firstIndex(of: "-dashboard"),
               i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]),
               model.dashboards.dashboards.indices.contains(n) {
                model.dashboards.selectedId = model.dashboards.dashboards[n].id
            }
            if CommandLine.arguments.contains("-dashboard-toolbar") {
                toolbar.show(for: .seconds(3600))
            }
            #endif
        case .preview(let id, let startEditing, _):
            previewSelection = id
            if startEditing, let d = model.dashboards.dashboard(id: id) { beginEditing(d) }
        }
    }

    // MARK: - Editing

    private func beginEditing(_ dashboard: Dashboard) {
        toolbar.hide()
        withAnimation(.snappy(duration: 0.25)) { edit = DashboardEditController(dashboard: dashboard) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func finishEditing() {
        guard let edit else { return }
        model.dashboards.update(edit.trimmed)
        withAnimation(.snappy(duration: 0.25)) { self.edit = nil }
    }

    // MARK: - Chrome

    /// Safety messages are never auto-hidden.
    @ViewBuilder
    private var healthPill: some View {
        if model.recording.samplesMayBePaused {
            pill("GPS went quiet — unlock to resume capture", icon: "exclamationmark.triangle.fill", color: .yellow)
        } else if model.forceScreenAwakeForSession {
            pill("Screen staying awake", icon: "sun.max.fill", color: .accent)
        }
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.sofia(14, .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.cardGray, in: Capsule())
        .padding(.top, 6)
        .allowsHitTesting(false)
    }
}

/// A red dot beside the trailing end of the Dynamic Island while a session
/// records — the same idea as the system's camera / mic dots. The island is
/// a system layer above every app, so nothing we draw inside the pill shows;
/// the dot sits just past its edge, on our own black. Island phones only
/// (safe inset ≥ 50 pt).
private struct RecordingIslandDot: View {
    let safe: EdgeInsets
    let size: CGSize
    let landscape: Bool

    /// Island: ~126 × 37 pt, centred, 11 pt from the sensor edge. The dot
    /// sits 10 pt past its trailing end.
    private static let halfLength: CGFloat = 63
    private static let gap: CGFloat = 10

    var body: some View {
        if landscape ? max(safe.leading, safe.trailing) >= 50 : safe.top >= 50 {
            // `safe` carries only the island's edge (see gridInsets).
            let center: CGPoint = landscape
                ? (safe.leading > 0
                   ? CGPoint(x: safe.leading / 2, y: size.height / 2 + Self.halfLength + Self.gap)
                   : CGPoint(x: size.width - safe.trailing / 2, y: size.height / 2 - Self.halfLength - Self.gap))
                : CGPoint(x: size.width / 2 + Self.halfLength + Self.gap, y: safe.top / 2)
            // Slow "live" pulse: the halo breathes out and fades while the
            // core dims slightly, on a 1.6 s cycle driven by the clock.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let ease = 0.5 - 0.5 * cos(t * 2 * .pi)          // 0 → 1 → 0
                ZStack {
                    Circle().fill(Color.toolbarRed.opacity(0.4 * (1 - ease)))
                        .frame(width: 10 + 12 * ease, height: 10 + 12 * ease)
                    Circle().fill(Color.toolbarRed.opacity(0.7 + 0.3 * (1 - ease)))
                        .frame(width: 7, height: 7)
                }
            }
            .position(center)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The screen's own safe area (notch, home indicator) regardless of any
/// navigation bar above the current view.
enum DeviceSafeArea {
    @MainActor private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    @MainActor static func insets() -> EdgeInsets? {
        guard let i = scene?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets else { return nil }
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// What the dashboard keeps clear: the sensor housing only. Portrait →
    /// the top. Landscape → iOS reports the same inset on both sides, but
    /// only one carries the island; the interface orientation says which.
    @MainActor static func gridInsets(fallback: EdgeInsets) -> EdgeInsets {
        let i = insets() ?? fallback
        switch scene?.interfaceOrientation {
        case .landscapeRight:   // device top edge on the left
            return EdgeInsets(top: 0, leading: i.leading, bottom: 0, trailing: 0)
        case .landscapeLeft:    // device top edge on the right
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: i.trailing)
        default:
            return EdgeInsets(top: i.top, leading: 0, bottom: 0, trailing: 0)
        }
    }
}
