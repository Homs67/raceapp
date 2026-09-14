//
//  GridBordersCanvas.swift
//  raceApp
//
//  All cell borders in one pass. Widgets have zero spacing, so per-widget
//  strokes would land side by side and read as 2 pt; stroking each frame here
//  at the same half-pixel-snapped coordinates makes shared edges one line.
//  Cells on the dashboard's outer corners are rounded there, so the group
//  reads as one rounded panel without clipping anything (badges hang out).
//  Empty cells and the slot a lifted widget will drop into are dashed.
//

import SwiftUI

struct GridBordersCanvas: View {
    let geom: GridGeometry
    let frames: [CGRect]
    let emptyCells: [CGRect]
    /// Packed slot of the widget being dragged — drawn as a target, not solid.
    var draggingFrame: CGRect?
    let editing: Bool

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            var borders = Path()
            for f in frames where f != draggingFrame { borders.addPath(cellPath(f)) }
            ctx.stroke(borders, with: .color(Color.widgetBorder), lineWidth: WidgetMetrics.borderWidth)

            if editing {
                var targets = Path()
                for f in emptyCells { targets.addPath(cellPath(f)) }
                if let d = draggingFrame { targets.addPath(cellPath(d)) }
                ctx.stroke(targets, with: .color(Color.mutedWeak),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                for f in emptyCells {
                    let c = CGPoint(x: f.midX, y: f.midY)
                    var plus = Path()
                    plus.move(to: CGPoint(x: c.x - 9, y: c.y)); plus.addLine(to: CGPoint(x: c.x + 9, y: c.y))
                    plus.move(to: CGPoint(x: c.x, y: c.y - 9)); plus.addLine(to: CGPoint(x: c.x, y: c.y + 9))
                    ctx.stroke(plus, with: .color(Color.mutedStrong), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The cell's edges, minus any that lie on the dashboard's outer edge —
    /// the screen edge is the border there.
    private func cellPath(_ f: CGRect) -> Path {
        let r = snapped(f)
        let b = geom.bounds
        let eps: CGFloat = 1.5
        var path = Path()
        func edge(_ a: CGPoint, _ c: CGPoint, outer: Bool) {
            guard !outer else { return }
            path.move(to: a); path.addLine(to: c)
        }
        edge(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), outer: abs(f.minY - b.minY) < eps)
        edge(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), outer: abs(f.maxY - b.maxY) < eps)
        edge(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), outer: abs(f.minX - b.minX) < eps)
        edge(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), outer: abs(f.maxX - b.maxX) < eps)
        return path
    }

    /// 1 pt lines centred on x.5 cover exactly one pixel row on 2x/3x screens.
    private func snapped(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5,
               width: r.width.rounded() - 1, height: r.height.rounded() - 1)
    }
}
