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
    /// Live, full-screen dashboard: outer edges are the glass, so they're not
    /// drawn and lines fade before reaching them. Preview / edit (zoomed
    /// out) draw every cell fully outlined.
    var edgeToEdge = true

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            if edgeToEdge {
                for f in frames where f != draggingFrame {
                    for seg in cellSegments(f) { strokeFading(seg, in: &ctx) }
                }
            } else {
                var borders = Path()
                for f in frames where f != draggingFrame { borders.addRect(snapped(f)) }
                ctx.stroke(borders, with: .color(Color.widgetBorder), lineWidth: WidgetMetrics.borderWidth)
            }

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

    /// Lines fade to black over their last 20 pt before the dashboard's edge.
    private static let fadeLength: CGFloat = 20

    private struct Segment {
        var a: CGPoint, b: CGPoint
        var fadeAtA: Bool, fadeAtB: Bool
    }

    /// The cell's edges, minus any that lie on the dashboard's outer edge —
    /// the screen edge is the border there. Ends that reach the outer edge
    /// are flagged so they can fade out.
    private func cellSegments(_ f: CGRect) -> [Segment] {
        let r = snapped(f)
        let b = geom.bounds
        let eps: CGFloat = 1.5
        let onLeft = abs(f.minX - b.minX) < eps, onRight = abs(f.maxX - b.maxX) < eps
        let onTop = abs(f.minY - b.minY) < eps, onBottom = abs(f.maxY - b.maxY) < eps
        var segs: [Segment] = []
        if !onTop { segs.append(Segment(a: CGPoint(x: r.minX, y: r.minY), b: CGPoint(x: r.maxX, y: r.minY), fadeAtA: onLeft, fadeAtB: onRight)) }
        if !onBottom { segs.append(Segment(a: CGPoint(x: r.minX, y: r.maxY), b: CGPoint(x: r.maxX, y: r.maxY), fadeAtA: onLeft, fadeAtB: onRight)) }
        if !onLeft { segs.append(Segment(a: CGPoint(x: r.minX, y: r.minY), b: CGPoint(x: r.minX, y: r.maxY), fadeAtA: onTop, fadeAtB: onBottom)) }
        if !onRight { segs.append(Segment(a: CGPoint(x: r.maxX, y: r.minY), b: CGPoint(x: r.maxX, y: r.maxY), fadeAtA: onTop, fadeAtB: onBottom)) }
        return segs
    }

    /// One stroke; the last `fadeLength` at a flagged end runs border → black.
    private func strokeFading(_ s: Segment, in ctx: inout GraphicsContext) {
        let width = WidgetMetrics.borderWidth
        let length = hypot(s.b.x - s.a.x, s.b.y - s.a.y)
        guard length > 0 else { return }
        let dir = CGPoint(x: (s.b.x - s.a.x) / length, y: (s.b.y - s.a.y) / length)
        let fade = min(Self.fadeLength, length / 2)
        func at(_ d: CGFloat) -> CGPoint { CGPoint(x: s.a.x + dir.x * d, y: s.a.y + dir.y * d) }
        let solidStart = s.fadeAtA ? fade : 0
        let solidEnd = s.fadeAtB ? length - fade : length
        if solidEnd > solidStart {
            var p = Path(); p.move(to: at(solidStart)); p.addLine(to: at(solidEnd))
            ctx.stroke(p, with: .color(Color.widgetBorder), lineWidth: width)
        }
        let ramp = Gradient(colors: [.black, Color.widgetBorder])
        if s.fadeAtA {
            var p = Path(); p.move(to: at(0)); p.addLine(to: at(fade))
            ctx.stroke(p, with: .linearGradient(ramp, startPoint: at(0), endPoint: at(fade)), lineWidth: width)
        }
        if s.fadeAtB {
            var p = Path(); p.move(to: at(length)); p.addLine(to: at(length - fade))
            ctx.stroke(p, with: .linearGradient(ramp, startPoint: at(length), endPoint: at(length - fade)), lineWidth: width)
        }
    }

    /// Dashed targets: full outline when zoomed out, edge-aware when live.
    private func cellPath(_ f: CGRect) -> Path {
        guard edgeToEdge else { return Path(snapped(f)) }
        var path = Path()
        for seg in cellSegments(f) { path.move(to: seg.a); path.addLine(to: seg.b) }
        return path
    }

    /// 1 pt lines centred on x.5 cover exactly one pixel row on 2x/3x screens.
    private func snapped(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5,
               width: r.width.rounded() - 1, height: r.height.rounded() - 1)
    }
}
