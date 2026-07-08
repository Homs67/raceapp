//
//  GMeterView.swift
//  raceApp
//
//  Friction-circle G-meter per design: rings at 0.5/1.0 g, crosshair, cyan dot
//  with 40-point trail, amber peak-hold ring. Stale → dot hidden.
//

import SwiftUI

struct GMeterView: View {
    /// nil = no fresh IMU data (stale rule R2.5)
    var latG: Double?
    var longG: Double?
    var peakG: Double
    var trail: [CGPoint] // unit-circle coords (g-space), newest last
    var pointsPerG: CGFloat = 63

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let clampRadius = pointsPerG * 4 / 3

            // Rings at 0.5g and 1.0g
            for (g, opacity) in [(0.5, 0.09), (1.0, 0.15)] {
                let radius = pointsPerG * g
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(opacity)), lineWidth: 1)
            }
            // Crosshair
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - clampRadius, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + clampRadius, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - clampRadius))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + clampRadius))
            context.stroke(cross, with: .color(.white.opacity(0.07)), lineWidth: 1)

            // Peak-hold ring
            if peakG > 0.05 {
                let radius = min(pointsPerG * peakG, clampRadius)
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(.warnAmber), lineWidth: 1.5)
            }

            func place(_ point: CGPoint) -> CGPoint {
                var x = point.x * pointsPerG
                var y = point.y * pointsPerG
                let distance = (x * x + y * y).squareRoot()
                if distance > clampRadius {
                    x *= clampRadius / distance
                    y *= clampRadius / distance
                }
                return CGPoint(x: center.x + x, y: center.y + y)
            }

            // Trail
            if trail.count > 1 {
                var path = Path()
                path.move(to: place(trail[0]))
                for point in trail.dropFirst() { path.addLine(to: place(point)) }
                context.stroke(path, with: .color(Color.accentCyan.opacity(0.4)), lineWidth: 2)
            }

            // Live dot — only with fresh data
            if let latG, let longG {
                let dot = place(CGPoint(x: latG, y: -longG))
                context.fill(
                    Path(ellipseIn: CGRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14)),
                    with: .color(.accentCyan))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
