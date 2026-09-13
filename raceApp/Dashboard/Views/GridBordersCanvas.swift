//
//  GridBordersCanvas.swift
//  raceApp
//
//  All cell borders in one pass. Widgets have zero spacing, so per-widget
//  strokes would land side by side and read as 2 pt; stroking each frame here
//  at the same half-pixel-snapped coordinates makes shared edges one line.
//  Also dashes empty cells in edit mode so add targets are visible.
//

import SwiftUI

struct GridBordersCanvas: View {
    let frames: [CGRect]
    let emptyCells: [CGRect]
    let editing: Bool

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            var borders = Path()
            for f in frames { borders.addRect(snapped(f)) }
            ctx.stroke(borders, with: .color(Color.widgetBorder), lineWidth: WidgetMetrics.borderWidth)

            if editing {
                var empties = Path()
                for f in emptyCells { empties.addRect(snapped(f).insetBy(dx: 6, dy: 6)) }
                ctx.stroke(empties, with: .color(Color.mutedWeak),
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

    /// 1 pt lines centred on x.5 cover exactly one pixel row on 2x/3x screens.
    private func snapped(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5,
               width: r.width.rounded() - 1, height: r.height.rounded() - 1)
    }
}
