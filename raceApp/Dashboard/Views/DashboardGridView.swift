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
    /// The screen this grid fills and its safe-area insets, both by value:
    /// the page host insets and re-centres whatever it lays out, so nothing
    /// here is measured — the pager tells the grid exactly how big it is.
    let size: CGSize
    var safeArea: EdgeInsets = EdgeInsets()

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let landscape = verticalSizeClass == .compact
        let geom = GridGeometry(available: size, grid: dashboard.grid, landscape: landscape, safe: safeArea)
        Group {
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
                        let insets = Self.contentInsets(for: frame, screen: size, safe: safeArea)
                        WidgetChrome(context: WidgetContext(
                            placement: placement,
                            contentSize: CGSize(width: frame.width - insets.leading - insets.trailing,
                                                height: frame.height - insets.top - insets.bottom),
                            contentInsets: insets,
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
                                    in: RoundedRectangle(cornerRadius: WidgetMetrics.panelCornerRadius))
                        .overlay {
                            if lifted {
                                RoundedRectangle(cornerRadius: WidgetMetrics.panelCornerRadius)
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
        .frame(width: size.width, height: size.height)
    }

    /// 16 pt all round, plus the display-corner allowance on a side where the
    /// cell meets the glass in a corner — i.e. it touches that side edge with
    /// no safe inset there, and also the top or bottom edge.
    static func contentInsets(for frame: CGRect, screen: CGSize, safe: EdgeInsets) -> EdgeInsets {
        let p = WidgetMetrics.padding
        let eps: CGFloat = 1.5
        let touchesTopOrBottom = frame.minY < eps || abs(frame.maxY - screen.height) < eps
        let leftCorner = frame.minX < eps && safe.leading < eps && touchesTopOrBottom
        let rightCorner = abs(frame.maxX - screen.width) < eps && safe.trailing < eps && touchesTopOrBottom
        return EdgeInsets(top: p,
                          leading: p + (leftCorner ? WidgetMetrics.displayCornerAllowance : 0),
                          bottom: p,
                          trailing: p + (rightCorner ? WidgetMetrics.displayCornerAllowance : 0))
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
