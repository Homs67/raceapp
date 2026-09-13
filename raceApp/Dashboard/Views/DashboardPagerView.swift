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
        case recording(onCollapse: () -> Void)
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

    var body: some View {
        @Bindable var store = model.dashboards
        // The outer reader sees the real safe area; everything below ignores it
        // and would otherwise report zero insets.
        GeometryReader { outer in
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let live = feed.tick(model: model, now: uptimeNow(), date: context.date, metric: metric)
            let units = UnitsFormatter(metric: metric)
            let track = model.metrics.track ?? previewTrack
            let safe = outer.safeAreaInsets
            // Under a chrome bar the grid starts inside the safe area already.
            let belowChrome = EdgeInsets(top: 0, leading: safe.leading, bottom: safe.bottom, trailing: safe.trailing)

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if let edit {
                    VStack(spacing: 0) {
                        EditChrome(edit: edit, onDone: finishEditing)
                        DashboardGridView(dashboard: edit.working, live: live, track: track, units: units,
                                          edit: edit, safeArea: belowChrome)
                    }
                } else {
                    VStack(spacing: 0) {
                        if case .preview(_, _, let onClose) = mode {
                            PreviewChrome(onEdit: { if let d = store.selected { beginEditing(d) } }, onClose: onClose)
                        }
                        TabView(selection: pageSelection) {
                            ForEach(store.dashboards) { dashboard in
                                DashboardGridView(dashboard: dashboard, live: live, track: track, units: units,
                                                  onTap: { if mode.isRecording { toolbar.toggle() } },
                                                  safeArea: mode.isRecording ? safe : belowChrome)
                                    .tag(Optional(dashboard.id))
                                    .onLongPressGesture(minimumDuration: 0.5) {
                                        guard !model.recording.isRecording else { return }
                                        beginEditing(dashboard)
                                    }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .ignoresSafeArea()
                    }
                }

                healthPill

                if case .recording(let onCollapse) = mode, edit == nil, toolbar.visible {
                    RecordingToolbar(
                        elapsed: live.elapsed,
                        pageIndex: store.selectedIndex,
                        pageCount: store.dashboards.count,
                        onStop: { model.stopRecording() },
                        onInteract: { toolbar.touch() },
                        onCollapse: onCollapse)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .sheet(item: Binding(get: { edit?.sheet }, set: { edit?.sheet = $0 })) { sheet in
            if let edit {
                switch sheet {
                case .options(let id): WidgetOptionsSheet(edit: edit, placementId: id)
                case .library(let index): WidgetLibrarySheet(edit: edit, insertAt: index)
                }
            }
        }
        .onAppear(perform: configureForMode)
        .onChange(of: model.recording.isRecording) { _, recording in
            // A session starting underneath an editor saves and exits it.
            if recording, edit != nil { finishEditing() }
        }
    }

    // MARK: - Pages

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
        model.dashboards.update(edit.working)
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

/// Top bar while editing: name (tap to rename), + Add, Done.
private struct EditChrome: View {
    let edit: DashboardEditController
    let onDone: () -> Void
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 16) {
            Button {
                draftName = edit.working.name
                renaming = true
            } label: {
                HStack(spacing: 6) {
                    Text(edit.working.name).font(.sofia(20, .bold)).foregroundStyle(.white)
                    Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedStrong)
                }
            }
            Spacer()
            if let rejection = edit.lastRejection {
                Text(rejection).font(.sofia(14, .semibold)).foregroundStyle(Color.toolbarRed).lineLimit(1)
            }
            Button {
                edit.presentLibraryAppending()
            } label: {
                Label("Add", systemImage: "plus").font(.sofia(18, .bold))
            }
            .foregroundStyle(Color.accent)
            Button("Done", action: onDone)
                .font(.sofia(18, .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.accent, in: Capsule())
        }
        .padding(.horizontal, 54).padding(.top, 8)
        .alert("Dashboard name", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") { edit.rename(draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Chrome for the Settings preview: Edit / Close.
private struct PreviewChrome: View {
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button("Close", action: onClose)
            Spacer()
            Text("Long-press a widget to edit").font(.sofia(14, .semibold)).foregroundStyle(Color.muted)
            Spacer()
            Button("Edit", action: onEdit)
        }
        .font(.sofia(18, .bold))
        .foregroundStyle(Color.accent)
        .padding(.horizontal, 54).padding(.top, 8)
    }
}
