//
//  DashboardsSettingsView.swift
//  raceApp
//
//  Settings → Dashboards: the calm place to build, reorder, rename, duplicate
//  and delete dashboards. Opening one shows the live pager in preview mode,
//  where long-press (or Edit) enters the editor.
//

import SwiftUI

struct DashboardsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: PreviewTarget?

    private struct PreviewTarget: Identifiable {
        let id: UUID
        let startEditing: Bool
    }

    var body: some View {
        @Bindable var store = model.dashboards
        List {
            Section {
                ForEach(store.dashboards) { dashboard in
                    Button {
                        preview = PreviewTarget(id: dashboard.id, startEditing: false)
                    } label: {
                        HStack(spacing: 12) {
                            DashboardThumbnail(dashboard: dashboard)
                                .frame(width: 96, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dashboard.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.textPrimary)
                                Text("\(dashboard.placements.count) widgets").font(.system(size: 12)).foregroundStyle(Color.muted)
                            }
                            Spacer()
                            if dashboard.id == store.selectedId {
                                Text("Current").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accent)
                            }
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedWeak)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.remove(id: dashboard.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { _ = store.duplicate(id: dashboard.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .tint(Color.accent)
                    }
                    .contextMenu {
                        Button("Edit") { preview = PreviewTarget(id: dashboard.id, startEditing: true) }
                        Button("Duplicate") { _ = store.duplicate(id: dashboard.id) }
                        Button("Make current") { store.selectedId = dashboard.id }
                        Button("Delete", role: .destructive) { store.remove(id: dashboard.id) }
                    }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Dashboards")
            } footer: {
                Text("Swipe between dashboards while recording. Long-press any widget on the Record screen (when not recording) to edit in place.")
            }
            .listRowBackground(Color.cardBg)
            .textCase(nil)

            Section {
                Button {
                    let new = Dashboard(name: "Dashboard \(store.dashboards.count + 1)",
                                        placements: [WidgetPlacement(kind: .lapTime, size: .medium)])
                    if store.add(new) { preview = PreviewTarget(id: new.id, startEditing: true) }
                } label: {
                    Label("New dashboard", systemImage: "plus")
                }
                .disabled(store.dashboards.count >= Dashboard.maxCount)
                Button("Restore defaults") { store.resetToDefaults() }
                    .foregroundStyle(Color.recordRed)
            } footer: {
                if store.dashboards.count >= Dashboard.maxCount {
                    Text("Up to \(Dashboard.maxCount) dashboards.")
                }
            }
            .listRowBackground(Color.cardBg)
            .textCase(nil)
        }
        .scrollContentBackground(.hidden)
        .background(Color.bgScreen)
        .tint(Color.accent)
        .navigationTitle("Dashboards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .fullScreenCover(item: $preview) { target in
            DashboardPagerView(mode: .preview(dashboardId: target.id, startEditing: target.startEditing,
                                              onClose: { preview = nil }))
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("-dashboard-edit"), let id = store.selected?.id {
                preview = PreviewTarget(id: id, startEditing: true)
            }
            #endif
        }
    }
}

/// Static miniature of a dashboard's layout for list rows.
struct DashboardThumbnail: View {
    let dashboard: Dashboard

    var body: some View {
        GeometryReader { geo in
            let packed = GridPacker.pack(dashboard.placements, grid: dashboard.grid)
            let rects = GridPacker.stretch(packed)
            let cw = geo.size.width / CGFloat(dashboard.grid.cols)
            let ch = geo.size.height / CGFloat(dashboard.grid.rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black)
                ForEach(dashboard.placements) { p in
                    if let r = rects[p.id] {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(p.kind.isHero ? Color.accent.opacity(0.7) : Color.mutedStrong.opacity(0.6))
                            .frame(width: CGFloat(r.width) * cw - 2, height: CGFloat(r.height) * ch - 2)
                            .offset(x: CGFloat(r.x) * cw + 1, y: CGFloat(r.y) * ch + 1)
                    }
                }
            }
        }
    }
}
