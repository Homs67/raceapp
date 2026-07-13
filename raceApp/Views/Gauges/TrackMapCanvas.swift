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
    let track: Track
    let position: CLLocationCoordinate2D?

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
            let pad: CGFloat = 16
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
            ctx.stroke(line, with: .color(Color.accent.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            // Start/finish gate
            var gate = Path()
            gate.move(to: project(track.startFinish.pointA))
            gate.addLine(to: project(track.startFinish.pointB))
            ctx.stroke(gate, with: .color(.white), lineWidth: 2)

            // Car position
            if let position {
                let p = project(position)
                let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                ctx.fill(dot, with: .color(.white))
                ctx.stroke(dot, with: .color(Color.accent), lineWidth: 3)
            }
        }
    }
}
