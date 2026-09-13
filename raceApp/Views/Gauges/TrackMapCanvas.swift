//
//  TrackMapCanvas.swift
//  raceApp
//
//  Offline, glanceable mini-map for the recording dashboard: draws a track's
//  centerline and the live car position with a fading trail. Pure Canvas — no
//  network tiles (works on a mountain), dark, and cheap to redraw at 10 Hz.
//

import SwiftUI
import CoreLocation

struct TrackMapCanvas: View {
    /// Visual treatment: the accent look of the old dashboard face, or the
    /// quiet gray outline + white dot of the widget dashboards (Figma 125:4704).
    enum Style {
        case accent
        case outline

        var line: Color { self == .accent ? Color.accent.opacity(0.9) : Color.mapOutline }
        var lineWidth: CGFloat { self == .accent ? 3 : 2 }
        var gate: Color { self == .accent ? .white : Color.mapOutline }
        var dotStroke: Color? { self == .accent ? Color.accent : nil }
        var dotRadius: CGFloat { self == .accent ? 7 : 5 }
    }

    let track: Track
    let position: CLLocationCoordinate2D?
    var style: Style = .accent
    var padding: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            let coords = track.centerlineCoordinates
            guard coords.count > 2 else { return }

            var minLat = coords[0].latitude, maxLat = coords[0].latitude
            var minLon = coords[0].longitude, maxLon = coords[0].longitude
            for c in coords {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
            let midLat = (minLat + maxLat) / 2
            let cosLat = cos(midLat * .pi / 180)
            let spanX = max(1e-6, (maxLon - minLon) * cosLat)
            let spanY = max(1e-6, maxLat - minLat)
            let pad = padding
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY)
            let offX = (size.width - CGFloat(spanX) * scale) / 2
            let offY = (size.height - CGFloat(spanY) * scale) / 2

            func project(_ c: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(x: offX + CGFloat((c.longitude - minLon) * cosLat) * scale,
                        y: offY + CGFloat(maxLat - c.latitude) * scale)
            }

            // Centerline
            var line = Path()
            line.addLines(coords.map(project))
            line.closeSubpath()
            ctx.stroke(line, with: .color(style.line),
                       style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, lineJoin: .round))

            // Start/finish gate
            var gate = Path()
            gate.move(to: project(track.startFinish.pointA))
            gate.addLine(to: project(track.startFinish.pointB))
            ctx.stroke(gate, with: .color(style.gate), lineWidth: 2)

            // Car position
            if let position {
                let p = project(position)
                let r = style.dotRadius
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(.white))
                if let stroke = style.dotStroke { ctx.stroke(dot, with: .color(stroke), lineWidth: 3) }
            }
        }
    }
}
