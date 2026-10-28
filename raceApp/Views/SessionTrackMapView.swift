//
//  SessionTrackMapView.swift
//  raceApp
//
//  Full-screen track map for one session. Two separate controls: the map
//  menu picks what the line shows (speed, braking, or delta to the best lap),
//  and "+ Channels" picks which charts sit in the bottom panel. Lap step (or
//  ±10 s on a drive), play and scrub are pinned at the bottom whatever is selected.
//

import SwiftUI
import MapKit
import SessionKit

enum TrackMapMode: String, CaseIterable, Identifiable {
    case speed, braking, delta
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "Speed"
        case .braking: return "Braking"
        case .delta: return "Delta vs ★"
        }
    }
    var subtitle: String {
        switch self {
        case .speed: return "Line coloured slow → fast"
        case .braking: return "Brake zones + entry → min speed"
        case .delta: return "Gain / loss vs your best lap"
        }
    }
}

struct SessionTrackMapView: View {
    let analysis: SessionAnalysis
    let track: Track?
    let layout: CourseLayout?
    @State var lapId: Int

    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false
    @State private var mode: TrackMapMode = .speed
    @State private var satellite = false
    @State private var channels: [AnalysisChannel] = [.speed]
    @State private var cursor: Double = 0          // samples into the lap
    @State private var playing = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var overlay = MapOverlay()
    @State private var panelHeight: CGFloat = 300

    private var units: UnitsFormatter { UnitsFormatter(metric: metric) }
    private var laps: [SessionAnalysis.Lap] { analysis.navigableLaps }
    private var lap: SessionAnalysis.Lap { laps.first { $0.id == lapId } ?? laps[0] }
    private var range: ClosedRange<Int> { analysis.indices(lap) }
    private var cursorIndex: Int { min(range.upperBound, range.lowerBound + Int(cursor)) }

    var body: some View {
        ZStack {
            // Frame the lap in the part of the map the controls don't cover.
            map.safeAreaPadding(.top, 60).safeAreaPadding(.bottom, panelHeight + 40).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                panel
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task(id: "\(lapId)-\(mode.rawValue)") { rebuildOverlay(refit: true) }
        .task(id: playing) { await play() }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera) {
            if let track, track.centerline.count > 2 {
                MapPolyline(coordinates: track.centerlineCoordinates)
                    .stroke(Color.white.opacity(satellite ? 0.25 : 0.12), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            }
            switch mode {
            case .speed, .delta:
                ForEach(overlay.segments) { seg in
                    MapPolyline(coordinates: seg.coordinates)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            case .braking:
                MapPolyline(coordinates: overlay.line)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(overlay.zones) { zone in
                    MapPolyline(coordinates: zone.coordinates)
                        .stroke(Color.recordRed, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    if zone.labeled {
                        Annotation("", coordinate: zone.coordinates[0], anchor: .bottom) {
                            brakeLabel(zone)
                        }
                    }
                }
            }
            if let gate = layout?.start {
                GateMapContent(gate: gate, color: .green, label: layout?.finish == nil ? "Start/finish" : "Start")
            }
            if let gate = layout?.finish { GateMapContent(gate: gate, color: .white, label: "Finish") }
            if analysis.lat.indices.contains(cursorIndex) {
                Annotation("", coordinate: analysis.coordinate(cursorIndex)) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 30, height: 30)
                        Circle().fill(Color.white).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.black, lineWidth: 2.5))
                    }
                }
            }
        }
        .mapStyle(satellite ? .imagery(elevation: .flat)
                  : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { }
    }

    private func brakeLabel(_ zone: MapOverlay.Zone) -> some View {
        HStack(spacing: 4) {
            Text(zone.corner).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mutedStrong)
            Text("\(zone.entry)→\(zone.min)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color(white: 0.11).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            circleButton("xmark") { dismiss() }
            Spacer()
            Menu {
                Picker("Map", selection: $mode) {
                    ForEach(TrackMapMode.allCases) { m in
                        if m != .delta || analysis.bestLapId != nil {
                            Text(m.title).tag(m)
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 8) {
                    modeSwatch(mode)
                    Text(mode.title).font(.system(size: 15, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.mutedStrong)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            Spacer()
            circleButton("globe", on: satellite) { satellite.toggle() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    @ViewBuilder private func modeSwatch(_ m: TrackMapMode) -> some View {
        switch m {
        case .speed: Circle().fill(SpeedColor.gradient).frame(width: 14, height: 14)
        case .braking: Circle().fill(Color.recordRed).frame(width: 14, height: 14)
        case .delta:
            HStack(spacing: -4) {
                Circle().fill(Color(hex: 0x30D158)).frame(width: 12, height: 12)
                Circle().fill(Color.recordRed).frame(width: 12, height: 12)
            }
        }
    }

    private func circleButton(_ symbol: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(on ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(on ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom panel

    private var panel: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 36, height: 5)
            panelHeader
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            divider
            charts
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
            divider
            VStack(spacing: 14) {
                transport
                timeline
            }
            .padding(.horizontal, 20).padding(.top, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        // The panel runs to the screen edge; its controls stay above the home indicator.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(Color(white: 0.11).opacity(0.97))
                .shadow(color: .black.opacity(0.5), radius: 20, y: -6)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
    }

    private var isDrive: Bool { lap.kind == .drive }

    private func title(_ l: SessionAnalysis.Lap) -> String {
        switch l.kind {
        case .timed, .dnf: return "Lap \(l.number)"
        case .outLap: return "Out lap"
        case .inLap: return "In lap"
        case .drive: return "Drive"
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(lap)).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                Text(RunFormat.time(lap.duration))
                    .font(.system(size: 20, weight: .regular)).monospacedDigit()
                    .foregroundStyle(Color.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(analysis.available) { ch in
                    Toggle(ch.title, isOn: Binding(
                        get: { channels.contains(ch) },
                        set: { on in
                            if on { channels = AnalysisChannel.allCases.filter { channels.contains($0) || $0 == ch } }
                            else if channels.count > 1 { channels.removeAll { $0 == ch } }
                        }))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text(channels.count > 1 ? "Channels · \(channels.count)" : "Channels").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color.white.opacity(0.1), in: Capsule())
            }
            .menuActionDismissBehavior(.disabled)
            .menuOrder(.fixed)
        }
    }

    @ViewBuilder private var charts: some View {
        let shown = channels.filter { analysis.available.contains($0) }
        let stack = VStack(spacing: 10) {
            ForEach(shown) { ch in channelChart(ch) }
        }
        if shown.count > 3 {
            ScrollView { stack }.frame(maxHeight: 300)
        } else {
            stack
        }
    }

    private func channelChart(_ ch: AnalysisChannel) -> some View {
        let values = overlay.series[ch] ?? []
        let v = analysis.value(ch, at: cursorIndex, lap: lap)
        let frac = range.count > 1 ? cursor / Double(range.count - 1) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ch.title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Color.muted)
                Spacer()
                Text(v.map { ch.format($0, units) } ?? "–")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ch == .brake || (ch == .gap && (v ?? 0) > 0) ? Color.recordRed : .white)
                let unit = ch.unit(units)
                if !unit.isEmpty { Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted) }
            }
            ChannelLine(values: values, color: ch.color, symmetric: ch.symmetric)
                .equatable()
                .frame(height: ch == .gear ? 40 : 54)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().fill(Color.white).frame(width: 3)
                            .offset(x: geo.size.width * frac - 1.5)
                    }
                }
        }
    }

    // MARK: - Transport

    /// Lap step on either side of play; a drive has no laps, so ±10 s instead.
    @ViewBuilder private var transport: some View {
        if isDrive {
            HStack(spacing: 32) {
                skipButton(-10)
                playButton
                skipButton(10)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                lapButton(offset: -1)
                Spacer(minLength: 8)
                playButton
                Spacer(minLength: 8)
                lapButton(offset: 1)
            }
        }
    }

    private var playButton: some View {
        Button { playing.toggle() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: playing ? 0 : 2)
                .frame(width: 56, height: 56)
                .background(Color.white, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Round ±10 s button, the same size as play. The trianglehead rewind
    /// symbols are iOS 18+; iOS 17 falls back to the older gobackward.10 pair.
    private func skipButton(_ seconds: Double) -> some View {
        let back = seconds < 0
        let symbol: String
        if #available(iOS 18, *) {
            symbol = back ? "10.arrow.trianglehead.counterclockwise" : "10.arrow.trianglehead.clockwise"
        } else {
            symbol = back ? "gobackward.10" : "goforward.10"
        }
        return Button { skip(seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(back ? "Back 10 seconds" : "Forward 10 seconds")
    }

    @ViewBuilder private func lapButton(offset: Int) -> some View {
        let i = laps.firstIndex { $0.id == lapId } ?? 0
        let target = laps.indices.contains(i + offset) ? laps[i + offset] : nil
        stepButton(symbol: offset < 0 ? "chevron.left" : "chevron.right",
                   label: target.map(title) ?? (offset < 0 ? "Previous" : "Next"),
                   leading: offset < 0) {
            guard let target else { return }
            lapId = target.id
            cursor = 0
        }
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1)
    }

    private func stepButton(symbol: String, label: String, leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if leading { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
                Text(label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if !leading { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .padding(.leading, leading ? 14 : 18).padding(.trailing, leading ? 18 : 14)
            .frame(width: 112, height: 40)
            .background(Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func skip(_ seconds: Double) {
        cursor = max(0, min(Double(range.count - 1), cursor + seconds * SessionAnalysis.hz))
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            HStack {
                Text(RunFormat.time(cursor / SessionAnalysis.hz))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(RunFormat.time(lap.duration))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted)
            }
            .monospacedDigit()
            GeometryReader { geo in
                let frac = range.count > 1 ? cursor / Double(range.count - 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Color.accent).frame(width: geo.size.width * frac, height: 4)
                    Circle().fill(Color.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: geo.size.width * frac - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // Touch, hold and drag to scrub back and forth.
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    playing = false
                    let f = max(0, min(1, g.location.x / max(1, geo.size.width)))
                    cursor = f * Double(range.count - 1)
                })
            }
            .frame(height: 24)
        }
    }

    // MARK: - Playback

    private func play() async {
        guard playing else { return }
        if Int(cursor) >= range.count - 1 { cursor = 0 }
        while playing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            cursor += SessionAnalysis.hz / 30
            if Int(cursor) >= range.count - 1 {
                // Roll into the next lap; stop after the last one.
                if let i = laps.firstIndex(where: { $0.id == lapId }), i + 1 < laps.count {
                    lapId = laps[i + 1].id
                    cursor = 0
                } else {
                    cursor = Double(range.count - 1)
                    playing = false
                }
            }
        }
    }

    // MARK: - Overlay

    private func rebuildOverlay(refit: Bool) {
        overlay = MapOverlay.build(analysis, lap: lap, mode: mode)
        if refit, !overlay.line.isEmpty {
            withAnimation { camera = .region(MapRegion.fitting(overlay.line, minSpanMeters: 250)) }
        }
    }
}

/// Precomputed map lines and chart series for the selected lap.
struct MapOverlay {
    struct Segment: Identifiable { let id: Int; let coordinates: [CLLocationCoordinate2D]; let color: Color }
    struct Zone: Identifiable { let id: Int; let corner: String; let coordinates: [CLLocationCoordinate2D]; let entry: Int; let min: Int; var labeled = true }

    var line: [CLLocationCoordinate2D] = []
    var segments: [Segment] = []
    var zones: [Zone] = []
    var series: [AnalysisChannel: [Double]] = [:]

    static func build(_ a: SessionAnalysis, lap: SessionAnalysis.Lap, mode: TrackMapMode) -> MapOverlay {
        var o = MapOverlay()
        let r = a.indices(lap)
        guard r.count > 1, !a.lat.isEmpty else { return o }
        let step = max(1, r.count / 1500)
        let idx = Array(stride(from: r.lowerBound, through: r.upperBound, by: step))
        o.line = idx.map { a.coordinate($0) }

        // Colour classes along the lap, merged into contiguous polylines.
        func segments(_ cls: (Int) -> Int, _ color: (Int) -> Color) -> [Segment] {
            var out: [Segment] = []
            var start = 0
            for k in 1...idx.count {
                if k == idx.count || cls(idx[k]) != cls(idx[start]) {
                    let coords = Array(o.line[start...min(k, idx.count - 1)])
                    if coords.count > 1 { out.append(Segment(id: out.count, coordinates: coords, color: color(cls(idx[start])))) }
                    start = k
                }
            }
            return out
        }
        switch mode {
        case .speed:
            let speed = a.channels[.speed] ?? []
            let sr = a.speedRange, buckets = 14
            o.segments = segments({ i in
                let v = speed[safe: i] ?? sr.lowerBound
                return v.isFinite ? max(0, min(buckets - 1, Int((v - sr.lowerBound) / (sr.upperBound - sr.lowerBound) * Double(buckets)))) : 0
            }, { b in SpeedColor.color((Double(b) + 0.5) / Double(buckets)) })
        case .delta:
            let gap = a.gap(lap) ?? []
            o.segments = segments({ i in
                let k = i - r.lowerBound, w = 10
                guard let g1 = gap[safe: min(gap.count - 1, k + w)], let g0 = gap[safe: max(0, k - w)] else { return 1 }
                let rate = g1 - g0      // seconds gained/lost over ~2 s of driving
                return rate > 0.02 ? 2 : rate < -0.02 ? 0 : 1
            }, { c in c == 0 ? Color(hex: 0x30D158) : c == 2 ? .recordRed : Color.white.opacity(0.45) })
        case .braking:
            let units = UnitsFormatter(metric: UserDefaults.standard.bool(forKey: "useMetricUnits"))
            o.zones = a.brakeZones(lap).map { z in
                Zone(id: z.id, corner: z.corner,
                     coordinates: (z.startIndex...max(z.startIndex + 1, z.endIndex)).map { a.coordinate($0) },
                     entry: Int(units.speed(fromMps: z.entrySpeed).rounded()), min: Int(units.speed(fromMps: z.minSpeed).rounded()))
            }
            // Label the bigger stops first; skip labels that would sit on top of one already placed.
            var placed: [CLLocationCoordinate2D] = []
            for k in o.zones.indices.sorted(by: { o.zones[$0].entry - o.zones[$0].min > o.zones[$1].entry - o.zones[$1].min }) {
                let c = o.zones[k].coordinates[0]
                let mLon = 111_320 * cos(c.latitude * .pi / 180)
                let clear = placed.allSatisfy { p in
                    let dx = (p.longitude - c.longitude) * mLon, dy = (p.latitude - c.latitude) * 110_540
                    return dx * dx + dy * dy > 130 * 130
                }
                o.zones[k].labeled = clear
                if clear { placed.append(c) }
            }
        }
        // Chart series for every available channel, ~300 points across the lap.
        let cstep = max(1, r.count / 300)
        let units = UnitsFormatter(metric: UserDefaults.standard.bool(forKey: "useMetricUnits"))
        for ch in a.available {
            if ch == .gap {
                if let g = a.gap(lap) { o.series[ch] = stride(from: 0, to: g.count, by: cstep).map { g[$0] } }
            } else if let v = a.channels[ch] {
                o.series[ch] = stride(from: r.lowerBound, through: r.upperBound, by: cstep).map { ch.display(v[$0], units) }
            }
        }
        return o
    }
}

/// A channel trace across the lap, drawn to fill its frame.
struct ChannelLine: View, Equatable {
    let values: [Double]
    let color: Color
    let symmetric: Bool

    var body: some View {
        Canvas { ctx, size in
            let finite = values.filter(\.isFinite)
            guard finite.count > 1, var lo = finite.min(), var hi = finite.max() else { return }
            if symmetric { let b = max(abs(lo), abs(hi), 0.05); lo = -b; hi = b }
            if hi - lo < 1e-6 { hi = lo + 1 }
            func y(_ v: Double) -> CGFloat { size.height - CGFloat((v - lo) / (hi - lo)) * size.height }
            var grid = Path()
            for f in [0.0, 0.5, 1.0] { grid.move(to: CGPoint(x: 0, y: size.height * f)); grid.addLine(to: CGPoint(x: size.width, y: size.height * f)) }
            ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            if symmetric {
                var z = Path(); z.move(to: CGPoint(x: 0, y: y(0))); z.addLine(to: CGPoint(x: size.width, y: y(0)))
                ctx.stroke(z, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
            }
            var p = Path()
            var pen = false
            for (k, v) in values.enumerated() {
                guard v.isFinite else { pen = false; continue }
                let pt = CGPoint(x: size.width * CGFloat(k) / CGFloat(values.count - 1), y: y(v))
                if pen { p.addLine(to: pt) } else { p.move(to: pt); pen = true }
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }
}
