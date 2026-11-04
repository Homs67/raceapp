//
//  TrackCard.swift
//  raceApp
//
//  Tracks tab grid card (design/tracks-grid, option 1 "Stacked"): name,
//  type, the track's shape, number of sessions — top to bottom.
//
//  The shape is drawn as lines, no map image:
//  - a bundled circuit: its centerline;
//  - a custom track: the best run or lap driven on it, with its start
//    (white) and finish (orange) lines;
//  - lines set but nothing driven: just the lines;
//  - nothing set yet: a dot.
//

import SwiftUI
import CoreLocation
import SessionKit

struct TrackCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let stats: TrackStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.sofia(20, .bold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 5) {
                    kindIcon
                    Text(track.trackKind.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mutedStrong)
                }
            }
            .padding([.horizontal, .top], 12)

            TrackShapeView(track: track, bestRun: stats?.bestRun,
                           directory: stats?.bestRun.map { model.store.directory(for: $0.session) })
                .frame(height: 120)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.18),
                                           .init(color: .black, location: 0.8),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }

            Text(sessionsText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.muted)
                .padding([.horizontal, .bottom], 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var kindIcon: some View {
        if track.trackKind == .autocross {
            Image(systemName: Track.Kind.pointToPointSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accent)
        } else {
            CircuitGlyph()
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 15, height: 15)
        }
    }

    private var sessionsText: String {
        let n = stats?.sessions ?? 0
        return n == 0 ? "No sessions yet" : "\(n) session\(n == 1 ? "" : "s")"
    }
}

// MARK: - Shape

/// How a track shape is drawn: the grid card's thin accent line, or the
/// track page's white line with corner numbers and line tags.
struct TrackShapeStyle {
    var lineColor: Color = .accent
    var lineWidth: CGFloat = 2.6
    /// Numbered corner badges (bundled circuits).
    var cornerBadges = false
    /// "S/F", "START", "FINISH" tags instead of bare gate strokes.
    var gateTags = false
    /// One corner (by `n`) marked with an accent dot.
    var highlightCorner: Int?
    var padding = CGSize(width: 18, height: 14)

    static let card = TrackShapeStyle()
    static let page = TrackShapeStyle(lineColor: .white, lineWidth: 3.2, cornerBadges: true, gateTags: true,
                                      padding: CGSize(width: 34, height: 34))
}

struct TrackShapeView: View {
    let track: Track
    let bestRun: TrackStats.BestRun?
    let directory: URL?
    var style = TrackShapeStyle.card
    @State private var line: [CLLocationCoordinate2D]?

    private var key: String {
        "\(track.id)-\(track.updatedAt?.timeIntervalSince1970 ?? 0)-\(bestRun?.session.uuidString ?? "")-\(bestRun?.start ?? 0)"
    }

    var body: some View {
        Canvas { ctx, size in
            draw(in: &ctx, size: size)
        }
        .task(id: key) { line = await Self.loadLine(track: track, bestRun: bestRun, directory: directory) }
        .accessibilityHidden(true)
    }

    /// The circuit's centerline, or the best run's GPS between its start and finish.
    private static func loadLine(track: Track, bestRun: TrackStats.BestRun?,
                                 directory: URL?) async -> [CLLocationCoordinate2D] {
        if !track.centerline.isEmpty { return track.centerlineCoordinates }
        guard let bestRun, let directory else { return [] }
        return await Task.detached {
            let (lat, lon) = SessionTrackTiming.gps(in: directory)
            var out: [CLLocationCoordinate2D] = []
            for i in 0..<min(lat.count, lon.count) where lat[i].t >= bestRun.start && lat[i].t <= bestRun.end {
                out.append(CLLocationCoordinate2D(latitude: lat[i].value, longitude: lon[i].value))
            }
            let step = max(1, out.count / 600)
            return Swift.stride(from: 0, to: out.count, by: step).map { out[$0] } + (out.last.map { [$0] } ?? [])
        }.value
    }

    private var gates: [(gate: TimingGate, color: Color, tag: String)] {
        var out: [(TimingGate, Color, String)] = []
        let p2p = track.trackKind == .autocross
        if let g = track.startGate { out.append((g, style.gateTags ? .green : .white, p2p ? "START" : "S/F")) }
        if let g = track.finishGate, p2p { out.append((g, .accent, "FINISH")) }
        return out
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let line = self.line ?? []
        let gateEnds = gates.map { ($0.gate.endpoints, $0.color, $0.tag) }
        var all = line
        for (e, _, _) in gateEnds {
            all.append(CLLocationCoordinate2D(latitude: e.a.lat, longitude: e.a.lon))
            all.append(CLLocationCoordinate2D(latitude: e.b.lat, longitude: e.b.lon))
        }
        guard let first = all.first else {
            // Nothing set yet: a dot where the track will be.
            let r = CGRect(x: size.width / 2 - 4, y: size.height / 2 - 4, width: 8, height: 8)
            ctx.fill(Circle().path(in: r), with: .color(.accent))
            ctx.stroke(Circle().path(in: r), with: .color(.white), lineWidth: 1.2)
            return
        }

        // Equirectangular fit, padded so the line clears the fades.
        let k = cos(first.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> CGPoint { CGPoint(x: c.longitude * k, y: -c.latitude) }
        let pts = all.map(xy)
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let pad = style.padding
        // Never zoom in past ~120 m across, or a lone start line fills the card.
        let scale = min((size.width - 2 * pad.width) / max(maxX - minX, 1e-9),
                        (size.height - 2 * pad.height) / max(maxY - minY, 1e-9),
                        (size.width - 2 * pad.width) / (120 / 111_320))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        func screen(_ c: CLLocationCoordinate2D) -> CGPoint {
            let p = xy(c)
            return CGPoint(x: size.width / 2 + (p.x - cx) * scale, y: size.height / 2 + (p.y - cy) * scale)
        }

        if line.count > 1 {
            var path = Path()
            path.addLines(line.map(screen))
            ctx.stroke(path, with: .color(style.lineColor),
                       style: StrokeStyle(lineWidth: style.lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let n = style.highlightCorner, let c = track.corners.first(where: { $0.n == n }) {
            let p = screen(c.coordinate)
            ctx.fill(Circle().path(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(Color.accent.opacity(0.3)))
            ctx.fill(Circle().path(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(.accent))
        }
        if style.cornerBadges {
            for c in track.corners {
                let p = screen(c.coordinate)
                let r = CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
                ctx.fill(Circle().path(in: r), with: .color(Color(hex: 0x1F1F1F)))
                ctx.stroke(Circle().path(in: r), with: .color(Color(hex: 0x3A3A3C)), lineWidth: 1.2)
                ctx.draw(Text("\(c.n)").font(.system(size: 10, weight: .semibold)).foregroundColor(.white), at: p)
            }
        }
        for (e, color, tag) in gateEnds {
            let a = screen(CLLocationCoordinate2D(latitude: e.a.lat, longitude: e.a.lon))
            let b = screen(CLLocationCoordinate2D(latitude: e.b.lat, longitude: e.b.lon))
            // A 15 m line is a speck at track scale; keep it readable.
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let half = max(len / 2, 7)
            let u = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            var gp = Path()
            gp.move(to: CGPoint(x: mid.x - u.x * half, y: mid.y - u.y * half))
            gp.addLine(to: CGPoint(x: mid.x + u.x * half, y: mid.y + u.y * half))
            ctx.stroke(gp, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            if style.gateTags { drawTag(tag, color: color, at: CGPoint(x: mid.x, y: mid.y + 17), in: &ctx) }
        }
        // A circuit drawn from its centerline marks where the lap starts.
        if gateEnds.isEmpty, style.highlightCorner == nil, let start = line.first {
            let p = screen(start)
            if style.gateTags {
                drawTag("S/F", color: .accent, at: CGPoint(x: p.x, y: p.y), in: &ctx)
            } else {
                ctx.fill(Circle().path(in: CGRect(x: p.x - 3.6, y: p.y - 3.6, width: 7.2, height: 7.2)), with: .color(.white))
            }
        }
    }

    /// A small filled capsule with a caps label, centred on `p`.
    private func drawTag(_ text: String, color: Color, at p: CGPoint, in ctx: inout GraphicsContext) {
        let label = ctx.resolve(Text(text).font(.system(size: 10, weight: .bold)).kerning(0.4)
            .foregroundColor(color == .accent ? .white : .black))
        let size = label.measure(in: CGSize(width: 200, height: 40))
        let r = CGRect(x: p.x - size.width / 2 - 8, y: p.y - 10, width: size.width + 16, height: 20)
        ctx.fill(Capsule().path(in: r), with: .color(color))
        ctx.draw(label, at: p)
    }
}
