//
//  DashboardGridView.swift
//  raceApp
//
//  Lays one dashboard out: pack → stretch → point frames, widgets positioned
//  by offset from the top-leading corner so frame math stays identical to
//  GridGeometry, borders drawn once on top.
//

import SwiftUI
import SessionKit

struct DashboardGridView: View {
    let dashboard: Dashboard
    let live: LiveSnapshot
    let track: Track?
    let units: UnitsFormatter
    var edit: DashboardEditController?
    /// Tap on the dashboard outside edit mode (reveals the recording toolbar).
    var onTap: () -> Void = {}
    /// Safe-area insets of the screen this grid fills. Passed in explicitly
    /// because a GeometryReader that ignores the safe area reports none.
    var safeArea: EdgeInsets = EdgeInsets()

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geo in
            let landscape = verticalSizeClass == .compact
            let geom = GridGeometry(available: geo.size, grid: dashboard.grid, landscape: landscape,
                                    safeTop: safeArea.top, safeBottom: safeArea.bottom)
            let placements = edit?.working.placements ?? dashboard.placements
            let packed = GridPacker.pack(placements, grid: geom.grid)
            // View mode stretches partial rows (Figma); the editor shows the
            // strict unit grid so empty slots are real, tappable gaps.
            let stretched = edit == nil
                ? GridPacker.stretch(packed)
                : packed.frames.mapValues { UnitRect(x: Double($0.col), y: Double($0.row),
                                                     width: Double($0.cols), height: Double($0.rows)) }
            let frames = Dictionary(uniqueKeysWithValues: stretched.map { ($0.key, geom.frame(for: $0.value)) })

            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    if let frame = frames[placement.id] {
                        let lifted = edit?.dragging?.id == placement.id
                        // Lifted: origin + finger travel; otherwise the packed slot.
                        let shown = lifted && edit?.dragging != nil
                            ? edit!.dragging!.origin.offsetBy(dx: edit!.dragging!.translation.width,
                                                              dy: edit!.dragging!.translation.height)
                            : frame
                        WidgetChrome(context: WidgetContext(
                            placement: placement,
                            contentSize: CGSize(width: frame.width - 2 * WidgetMetrics.padding,
                                                height: frame.height - 2 * WidgetMetrics.padding),
                            isLandscape: landscape, live: live, units: units,
                            isEditing: edit != nil, track: track))
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        // One press gesture handles tap (options), hold (lift)
                        // and hold-then-move (reorder); a LongPress→Drag
                        // sequence at high priority swallowed plain taps.
                        .highPriorityGesture(edit.map { editGesture(for: placement, edit: $0, geom: geom, stretched: stretched) })
                        // A lifted widget takes its panel with it: the canvas
                        // leaves its slot dashed, so it draws its own bg/border.
                        .background(lifted ? Color.black : Color.clear,
                                    in: RoundedRectangle(cornerRadius: WidgetMetrics.outerCornerRadius))
                        .overlay {
                            if lifted {
                                RoundedRectangle(cornerRadius: WidgetMetrics.outerCornerRadius)
                                    .stroke(Color.widgetBorder, lineWidth: WidgetMetrics.borderWidth)
                            }
                        }
                        .scaleEffect(lifted ? 1.04 : (edit != nil ? 0.97 : 1))
                        .shadow(color: .black.opacity(lifted ? 0.6 : 0), radius: 18, y: 8)
                        .offset(x: shown.minX, y: shown.minY)
                        .zIndex(lifted ? 1 : 0)
                        .animation(lifted ? nil : .snappy(duration: 0.25), value: frame)
                    }
                }

                GridBordersCanvas(geom: geom, frames: Array(frames.values),
                                  emptyCells: packed.emptyCells.map { geom.frame(for: $0) },
                                  draggingFrame: edit?.dragging.flatMap { frames[$0.id] },
                                  editing: edit != nil)
                    .animation(.snappy(duration: 0.25), value: frames)

                // Badges last, so they sit above the border strokes.
                if let edit {
                    ForEach(placements) { placement in
                        if let frame = frames[placement.id], edit.dragging?.id != placement.id {
                            RemoveBadge(placement: placement, edit: edit)
                                .offset(x: frame.minX, y: frame.minY)
                                .animation(.snappy(duration: 0.25), value: frame)
                        }
                    }
                }
            }
            .coordinateSpace(name: "dashboardGrid")
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let edit else { onTap(); return }
                // Tap an empty cell in edit mode → add a widget there.
                guard let cell = geom.cell(at: location),
                      packed.isFree(row: cell.row, col: cell.col) else { return }
                let unit = geom.clampedUnitPoint(at: location)
                edit.presentLibrary(insertAtUnit: unit, stretched: stretched)
            }
        }
        // The page host (UIKit) insets its content by the safe area; undo
        // that so the grid gets the whole page and applies insets by value.
        .ignoresSafeArea()
    }

    private func editGesture(for placement: WidgetPlacement, edit: DashboardEditController,
                             geom: GridGeometry, stretched: [UUID: UnitRect]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("dashboardGrid"))
            .onChanged { drag in
                guard let rect = stretched[placement.id] else { return }
                let start = edit.dragging?.origin ?? geom.frame(for: rect)
                let center = CGPoint(x: start.midX + drag.translation.width,
                                     y: start.midY + drag.translation.height)
                edit.pressChanged(id: placement.id, frame: geom.frame(for: rect), translation: drag.translation,
                                  unit: geom.clampedUnitPoint(at: center), stretched: stretched)
            }
            .onEnded { _ in edit.pressEnded(id: placement.id) }
    }
}

/// Remove badge, only in edit mode. Options open from a tap on the chrome.
private struct RemoveBadge: View {
    let placement: WidgetPlacement
    let edit: DashboardEditController

    var body: some View {
        Button {
            edit.remove(id: placement.id)
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.toolbarRed)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: -12, y: -12)
        .accessibilityLabel("Remove \(placement.kind.title)")
    }
}
