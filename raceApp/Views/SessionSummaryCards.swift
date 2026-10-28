//
//  SessionSummaryCards.swift
//  raceApp
//
//  The blocks of the session summary: a vector map of the best lap coloured
//  by speed, the best-lap card, laps as bars, and drag splits.
//

import SwiftUI
import CoreLocation
import SessionKit
import WeatherKit

// MARK: - Hero map

/// Vector map (no tiles) of the best lap, or the whole drive when there are no
/// laps, coloured by speed. Tapping it opens the full-screen map.
struct SessionHeroMap: View {
    let analysis: SessionAnalysis
    let track: Track?
    var weather: SessionManifest.WeatherSnapshot? = nil
    @AppStorage("useMetricUnits") private var metric = false

    private var units: UnitsFormatter { UnitsFormatter(metric: metric) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.045)], startPoint: .top, endPoint: .bottom)
            grid
            Canvas { ctx, size in draw(ctx, size) }
                // Clear of the chip on top and the legend below.
                .padding(.top, 50).padding(.bottom, 34).padding(.horizontal, 20)
            overlays
        }
        .frame(height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    private var grid: some View {
        Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 24).forEach { p.move(to: .init(x: $0, y: 0)); p.addLine(to: .init(x: $0, y: size.height)) }
            stride(from: 0, through: size.height, by: 24).forEach { p.move(to: .init(x: 0, y: $0)); p.addLine(to: .init(x: size.width, y: $0)) }
            ctx.stroke(p, with: .color(.white.opacity(0.025)), lineWidth: 1)
        }
    }

    private var overlays: some View {
        VStack {
            HStack {
                if let w = weather {
                    conditionsChip(symbol: w.symbolName, text: [
                        "\(Int(units.temp(fromC: w.temperatureC).rounded()))°",
                        "\(Int((w.humidity * 100).rounded()))%",
                        "\(Int(units.speed(fromMps: w.windMps).rounded())) \(units.speedUnit.lowercased()) \(w.windCompass)",
                    ].joined(separator: "  ·  "))
                } else if let c = analysis.ambientC {
                    // No weather report: the car's own outside-air sensor.
                    conditionsChip(symbol: "thermometer.medium", text: "Air \(Int(units.temp(fromC: c).rounded()))° (car)")
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            HStack(spacing: 6) {
                let r = analysis.speedRange
                Text("\(Int(units.speed(fromMps: r.lowerBound)))").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                Capsule().fill(SpeedColor.gradient).frame(width: 56, height: 4)
                Text("\(Int(units.speed(fromMps: r.upperBound))) \(units.speedUnit.lowercased())").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                Spacer()
                if let best = analysis.bestLap {
                    Text("Best \(analysis.isLoop ? "lap" : "run") · \(analysis.isLoop ? "Lap" : "Run") \(best.number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                }
            }
        }
        .padding(12)
    }

    private func conditionsChip(symbol: String, text: String) -> some View {
        HStack(spacing: 6) {
            // Outline weather symbols have no multicolor layers; their .fill twins do.
            let filled = UIImage(systemName: symbol + ".fill") != nil ? symbol + ".fill" : symbol
            Image(systemName: filled).symbolRenderingMode(.multicolor).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(white: 0.11).opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let range: ClosedRange<Int>
        if let best = analysis.bestLap { range = analysis.indices(best) }
        else if analysis.t.count > 1 { range = 0...(analysis.t.count - 1) } else { return }
        let step = max(1, range.count / 800)
        let idx = Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
        let pts = idx.map { analysis.coordinate($0) }
        let outline = track.flatMap { $0.centerline.count > 2 ? $0.centerlineCoordinates : nil }
        let all = pts + (outline ?? [])
        guard let fit = GeoFit(all, in: size) else { return }
        if let outline {
            var o = Path()
            o.addLines(outline.map(fit.point))
            o.closeSubpath()
            ctx.stroke(o, with: .color(Color(hex: 0x2C2C30)), style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
            ctx.stroke(o, with: .color(Color(hex: 0x141416)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        }
        let speed = analysis.channels[.speed] ?? []
        let sr = analysis.speedRange
        for k in 1..<max(1, idx.count) {
            var p = Path()
            p.move(to: fit.point(analysis.coordinate(idx[k - 1])))
            p.addLine(to: fit.point(analysis.coordinate(idx[k])))
            let v = speed[safe: idx[k]] ?? sr.lowerBound
            let u = v.isFinite ? (v - sr.lowerBound) / (sr.upperBound - sr.lowerBound) : 0
            ctx.stroke(p, with: .color(SpeedColor.color(u)), style: StrokeStyle(lineWidth: 3.8, lineCap: .round))
        }
    }
}

/// Fits lat/lon points into a rect, north up, preserving aspect.
struct GeoFit {
    let lat0: Double, lon0: Double, mLon: Double, scale: Double, ox: Double, oy: Double

    init?(_ pts: [CLLocationCoordinate2D], in size: CGSize) {
        let valid = pts.filter { $0.latitude.isFinite && $0.longitude.isFinite }
        guard valid.count > 1 else { return nil }
        let la0 = valid[0].latitude, lo0 = valid[0].longitude
        let mx = 111_320 * cos(la0 * .pi / 180)
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for c in valid {
            let x = (c.longitude - lo0) * mx, y = -(c.latitude - la0) * 110_540
            minX = Swift.min(minX, x); maxX = Swift.max(maxX, x); minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
        }
        let s = Swift.min(Double(size.width) / Swift.max(1, maxX - minX), Double(size.height) / Swift.max(1, maxY - minY))
        lat0 = la0; lon0 = lo0; mLon = mx; scale = s
        ox = (Double(size.width) - (maxX - minX) * s) / 2 - minX * s
        oy = (Double(size.height) - (maxY - minY) * s) / 2 - minY * s
    }

    func point(_ c: CLLocationCoordinate2D) -> CGPoint {
        CGPoint(x: (c.longitude - lon0) * mLon * scale + ox, y: -(c.latitude - lat0) * 110_540 * scale + oy)
    }
}

// MARK: - Best lap + key stats

struct BestLapCard: View {
    let analysis: SessionAnalysis
    let manifest: SessionManifest
    /// Fastest lap on this track from other sessions.
    let previousBest: TimeInterval?
    @AppStorage("useMetricUnits") private var metric = false

    var body: some View {
        let units = UnitsFormatter(metric: metric)
        let h = manifest.highlights ?? .init()
        VStack(alignment: .leading, spacing: 14) {
            if let best = analysis.bestLap {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(analysis.isLoop ? "BEST LAP" : "BEST RUN").font(.microLabel(11)).kerning(0.6).foregroundStyle(Color.muted)
                        Text(RunFormat.time(best.duration)).font(.numeral(58, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let prev = previousBest {
                            let d = best.duration - prev
                            if d < 0 {
                                Text("NEW PB").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.accent, in: RoundedRectangle(cornerRadius: 6))
                            }
                            Text(String(format: "%+.2f vs %@", d, RunFormat.time(prev)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(d < 0 ? Color(hex: 0x30D158) : Color.mutedStrong)
                        }
                        let timed = analysis.laps.filter { $0.kind == .timed }
                        Text("\(best.label.replacingOccurrences(of: "L", with: analysis.isLoop ? "Lap " : "Run ")) of \(timed.count)")
                            .font(.system(size: 12)).foregroundStyle(Color.muted)
                    }
                    .padding(.bottom, 10)
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            }
            HStack(alignment: .top, spacing: 8) {
                stat("SESSION", formatDuration(h.durationSeconds), "",
                     analysis.timedLaps.isEmpty ? nil : "\(analysis.timedLaps.count) \(analysis.isLoop ? "lap" : "run")\(analysis.timedLaps.count == 1 ? "" : "s")")
                stat("TOP SPEED", String(format: "%.0f", units.speed(fromMps: h.maxSpeedMps)), units.speedUnit.lowercased(), nil)
                stat("DISTANCE", String(format: "%.1f", units.distance(fromMeters: h.distanceMeters)), units.distanceUnit, nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func stat(_ label: String, _ value: String, _ unit: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.microLabel(11)).foregroundStyle(Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.numeral(26)).foregroundStyle(.white)
                if !unit.isEmpty { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted) }
            }
            if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(Color.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Laps as bars

struct LapBarsCard: View {
    let analysis: SessionAnalysis
    let onSelect: (SessionAnalysis.Lap) -> Void

    var body: some View {
        let timed = analysis.laps.filter { $0.kind == .timed }
        let best = analysis.bestLap?.duration ?? 0
        let slow = timed.map(\.duration).max() ?? best
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(analysis.isLoop ? "LAPS" : "RUNS").font(.microLabel(11)).foregroundStyle(Color.muted)
                Spacer()
                Text(summary(timed)).font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            .padding(.bottom, 8)
            ForEach(analysis.laps) { lap in
                Button { onSelect(lap) } label: { row(lap, best: best, slow: slow) }
                    .buttonStyle(.plain)
            }
            Text("Tap a \(analysis.isLoop ? "lap" : "run") to open it on the map")
                .font(.system(size: 12)).foregroundStyle(Color.mutedWeak)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func summary(_ timed: [SessionAnalysis.Lap]) -> String {
        guard !timed.isEmpty else { return "" }
        let avg = timed.map(\.duration).reduce(0, +) / Double(timed.count)
        let dnf = analysis.laps.filter { $0.kind == .dnf }.count
        return "\(timed.count) timed · avg \(RunFormat.time(avg))" + (dnf > 0 ? " · \(dnf) DNF" : "")
    }

    private func row(_ lap: SessionAnalysis.Lap, best: Double, slow: Double) -> some View {
        let isBest = lap.id == analysis.bestLapId
        let dim = lap.kind == .outLap || lap.kind == .inLap
        let tint: Color = isBest ? .accent : lap.kind == .dnf ? .recordRed : dim ? .muted : .white
        let fraction: Double = {
            guard lap.kind == .timed, slow > best else { return 1 }
            return 0.1 + 0.9 * (lap.duration - best) / (slow - best)
        }()
        return HStack(spacing: 10) {
            Text(lap.number > 0 ? "\(lap.number)" : "–").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isBest ? Color.accent : dim ? Color.mutedWeak : Color.muted)
                .frame(width: 22, alignment: .leading)
            Text(lap.kind == .dnf ? "—" : RunFormat.time(lap.duration))
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.05))
                    if lap.kind == .dnf {
                        Capsule().strokeBorder(Color.recordRed.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else {
                        Capsule().fill(isBest ? Color.accent : Color.white.opacity(dim ? 0.12 : 0.32))
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
            .frame(height: 10)
            Text(deltaText(lap, best: best))
                .font(.system(size: isBest ? 11 : 13, weight: isBest ? .bold : .medium))
                .foregroundStyle(isBest ? Color.accent : lap.kind == .dnf ? .recordRed : dim ? Color.mutedWeak : Color.mutedStrong)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func deltaText(_ lap: SessionAnalysis.Lap, best: Double) -> String {
        switch lap.kind {
        case .outLap: return "Out lap"
        case .inLap: return "In lap"
        case .dnf: return "DNF"
        case .drive: return ""
        case .timed: return lap.id == analysis.bestLapId ? "BEST" : String(format: "+%.2f", lap.duration - best)
        }
    }
}

// MARK: - Drag

struct DragCard: View {
    let drag: SessionAnalysis.DragResult
    let raceBox: Bool
    @AppStorage("useMetricUnits") private var metric = false

    var body: some View {
        let units = UnitsFormatter(metric: metric)
        let rows: [(String, TimeInterval?, String?)] = metric
            ? [("0–100 km/h", drag.zeroTo100Kmh, nil), ("0–200 km/h", drag.zeroTo200Kmh, nil),
               ("400 m", drag.quarterMile, trap(units))]
            : [("0–60 mph", drag.zeroToSixty, nil), ("0–100 mph", drag.zeroToHundredMph, nil),
               ("¼ mile", drag.quarterMile, trap(units))]
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DRAG · BEST IN SESSION").font(.microLabel(11)).foregroundStyle(Color.muted)
                Spacer()
                Text(raceBox ? "RaceBox · 25 Hz" : "Phone GPS · approx")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mutedStrong)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { k, row in
                if k > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
                HStack(spacing: 8) {
                    Text(row.0).font(.system(size: 15))
                    Spacer()
                    if let sub = row.2, row.1 != nil { Text(sub).font(.system(size: 13)).foregroundStyle(Color.muted) }
                    Text(row.1.map { String(format: "%.1f s", $0) } ?? "—")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    if row.1 == nil { Text("not reached").font(.system(size: 13)).foregroundStyle(Color.muted) }
                }
                .padding(.vertical, 11)
            }
            Text("Standing starts only").font(.system(size: 12)).foregroundStyle(Color.mutedWeak)
        }
        .padding(16)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.cardBorder, lineWidth: 1))
    }

    private func trap(_ units: UnitsFormatter) -> String? {
        drag.quarterTrapMps.map { "@ \(Int(units.speed(fromMps: $0).rounded())) \(units.speedUnit.lowercased())" }
    }
}

// MARK: - Weather attribution

/// Apple Weather mark and legal link, required wherever its data is shown.
struct WeatherAttributionRow: View {
    @State private var attribution: WeatherAttribution?

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            if let attribution {
                AsyncImage(url: attribution.combinedMarkDarkURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text(" Weather").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                }
                .frame(height: 11)
                Link("Legal", destination: attribution.legalPageURL)
                    .font(.system(size: 11)).foregroundStyle(Color.muted).underline()
            }
        }
        .frame(height: 14)
        .padding(.horizontal, 4)
        .task { attribution = await SessionWeather.attribution() }
    }
}
