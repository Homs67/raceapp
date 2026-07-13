//
//  TrackNavCanvas.swift
//  raceApp
//
//  3D chase-cam navigation view: a perspective camera sits behind and above the
//  car looking down the track. The road is drawn as a perspective ribbon and the
//  racing line as a colour-coded strip (green = fast, amber = slow corner,
//  red = braking zone) so the driver can see the line to follow ahead. Pure
//  Canvas with a pinhole projection — no SceneKit, redraws cheaply at 10 Hz.
//

import SwiftUI
import CoreLocation

struct TrackNavCanvas: View {
    let nav: [NavPoint]
    let car: CLLocationCoordinate2D?
    let heading: Double

    // Camera
    private let camHeight = 5.0
    private let camBack = 8.0
    private let viewDistance = 340.0
    private let roadHalf = 9.0

    var body: some View {
        Canvas { ctx, size in
            let horizonY = size.height * 0.40
            drawBackground(ctx, size, horizonY)
            guard let car, !nav.isEmpty, heading.isFinite else { return }

            let cx = size.width / 2
            let focal = size.width * 0.95
            let hRad = heading * .pi / 180
            let sinH = sin(hRad), cosH = cos(hRad)
            let mLat = 110_540.0, mLon = 111_320.0 * cos(car.latitude * .pi / 180)

            func rel(_ c: CLLocationCoordinate2D) -> (s: Double, a: Double) {
                let dE = (c.longitude - car.longitude) * mLon
                let dN = (c.latitude - car.latitude) * mLat
                return (dE * cosH - dN * sinH, dE * sinH + dN * cosH)
            }
            func project(_ s: Double, _ a: Double) -> CGPoint? {
                let d = a + camBack
                guard d > 1 else { return nil }
                let scale = focal / d
                return CGPoint(x: cx + s * scale, y: horizonY + camHeight * scale)
            }
            func projC(_ c: CLLocationCoordinate2D) -> CGPoint? {
                let r = rel(c); return project(r.s, r.a)
            }
            func move(_ c: CLLocationCoordinate2D, bearing: Double, _ m: Double) -> CLLocationCoordinate2D {
                let b = bearing * .pi / 180
                return CLLocationCoordinate2D(latitude: c.latitude + m * cos(b) / mLat,
                                              longitude: c.longitude + m * sin(b) / mLon)
            }

            // Nearest centerline vertex to the car → start of the visible window.
            let n = nav.count
            var nearest = 0, bestD = Double.infinity
            for i in 0..<n {
                let r = rel(nav[i].center); let d = r.a * r.a + r.s * r.s
                if d < bestD { bestD = d; nearest = i }
            }

            // Collect visible segments (near → far), then paint far → near.
            struct Seg { let road: [CGPoint]; let a: NavPoint; let b: NavPoint; let pa: CGPoint; let pb: CGPoint }
            var segs: [Seg] = []
            var brakeAhead: Double?
            for k in -6..<n {                       // a few behind so the road reaches the car
                let i = (nearest + k + n) % n, j = (nearest + k + 1 + n) % n
                let p0 = nav[i], p1 = nav[j]
                let r0 = rel(p0.center)
                if k > 0, r0.a > viewDistance { break }
                guard let l0 = projC(move(p0.center, bearing: p0.heading - 90, roadHalf)),
                      let rr0 = projC(move(p0.center, bearing: p0.heading + 90, roadHalf)),
                      let l1 = projC(move(p1.center, bearing: p1.heading - 90, roadHalf)),
                      let rr1 = projC(move(p1.center, bearing: p1.heading + 90, roadHalf)),
                      let pa = projC(p0.racing), let pb = projC(p1.racing) else { continue }
                segs.append(Seg(road: [l0, rr0, rr1, l1], a: p0, b: p1, pa: pa, pb: pb))
                if brakeAhead == nil, p0.braking, r0.a > camBack { brakeAhead = r0.a }
            }

            // Road surface (far → near).
            for seg in segs.reversed() {
                var road = Path(); road.addLines(seg.road); road.closeSubpath()
                ctx.fill(road, with: .color(Color(white: 0.13)))
            }
            // Racing line (far → near), thickness grows toward the camera.
            for seg in segs.reversed() {
                var line = Path(); line.move(to: seg.pa); line.addLine(to: seg.pb)
                let width = max(2.0, 90.0 / (rel(seg.a.center).a + camBack))
                ctx.stroke(line, with: .color(Self.lineColor(seg.a)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            drawCar(ctx, size)
            if let brakeAhead, brakeAhead < 70 { drawBrakePrompt(ctx, size) }
        }
    }

    private static func lineColor(_ p: NavPoint) -> Color {
        if p.braking { return Color(red: 0.95, green: 0.24, blue: 0.18) }
        let t = p.speedNorm                       // 0 slow → 1 fast
        return Color(red: 1.0 - t * 0.85, green: 0.62 + t * 0.28, blue: 0.16)  // amber → green
    }

    private func drawBackground(_ ctx: GraphicsContext, _ size: CGSize, _ horizonY: CGFloat) {
        let sky = Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY))
        ctx.fill(sky, with: .linearGradient(
            Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.12), .black]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizonY)))
        let ground = Path(CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY))
        ctx.fill(ground, with: .color(Color(white: 0.05)))
    }

    private func drawCar(_ ctx: GraphicsContext, _ size: CGSize) {
        let cx = size.width / 2, y = size.height * 0.80, w = 16.0, h = 20.0
        var chevron = Path()
        chevron.move(to: CGPoint(x: cx, y: y - h / 2))
        chevron.addLine(to: CGPoint(x: cx - w / 2, y: y + h / 2))
        chevron.addLine(to: CGPoint(x: cx, y: y + h / 4))
        chevron.addLine(to: CGPoint(x: cx + w / 2, y: y + h / 2))
        chevron.closeSubpath()
        ctx.fill(chevron, with: .color(.white))
    }

    private func drawBrakePrompt(_ ctx: GraphicsContext, _ size: CGSize) {
        let text = Text("BRAKE").font(.system(size: 15, weight: .bold)).kerning(2).foregroundStyle(.white)
        let pill = Path(roundedRect: CGRect(x: size.width / 2 - 55, y: size.height * 0.14, width: 110, height: 30),
                        cornerRadius: 15)
        ctx.fill(pill, with: .color(Color(red: 0.9, green: 0.2, blue: 0.15)))
        ctx.draw(text, at: CGPoint(x: size.width / 2, y: size.height * 0.14 + 15))
    }
}
