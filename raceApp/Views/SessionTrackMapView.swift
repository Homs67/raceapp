//
//  SessionTrackMapView.swift
//  raceApp
//
//  Full-screen track map for one session. Two separate controls: the map
//  menu picks what the line shows (speed, braking, or delta to the best lap),
//  and "+ Channels" picks which charts sit in the bottom panel. Laps, play and
//  scrub are pinned at the bottom whatever is selected.
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
        .padding(.horizontal, 16)
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
        VStack(spacing: 12) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 36, height: 5)
            panelHeader
            charts
            VStack(spacing: 12) {
                lapStrip
                playBar
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(white: 0.11).opacity(0.97),
                    in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .shadow(color: .black.opacity(0.5), radius: 20, y: -6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            let isBest = lap.id == analysis.bestLapId
            Text(isBest ? "★ \(lap.label)" : lap.kind == .drive ? "Drive" : lap.label)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isBest ? Color.accent : .white)
            Text(lapSubtitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.muted)
            Spacer()
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
                    Text(channels.count > 1 ? "Channels · \(channels.count)" : "Channels").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.white.opacity(0.1), in: Capsule())
            }
            .menuActionDismissBehavior(.disabled)
            .menuOrder(.fixed)
        }
    }

    private var lapSubtitle: String {
        var s = RunFormat.time(lap.duration)
        if lap.kind == .timed, let best = analysis.bestLap, best.id != lap.id {
            s += String(format: " · %+.2f", lap.duration - best.duration)
        }
        return s
    }

    @ViewBuilder private var charts: some View {
        let shown = channels.filter { analysis.available.contains($0) }
        let stack = VStack(spacing: 10) {
            ForEach(shown) { ch in channelChart(ch) }
        }
        if shown.count > 3 {
            ScrollView { stack }.frame(maxHeight: 250)
        } else {
            stack
        }
    }

    private func channelChart(_ ch: AnalysisChannel) -> some View {
        let values = overlay.series[ch] ?? []
        let v = analysis.value(ch, at: cursorIndex, lap: lap)
        let frac = range.count > 1 ? cursor / Double(range.count - 1) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ch.title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.muted)
                Spacer()
                Text(v.map { ch.format($0, units) } ?? "–")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ch == .brake || (ch == .gap && (v ?? 0) > 0) ? Color.recordRed : .white)
                let unit = ch.unit(units)
                if !unit.isEmpty { Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted) }
            }
            ChannelLine(values: values, color: ch.color, symmetric: ch.symmetric)
                .equatable()
                .frame(height: ch == .gear ? 26 : 40)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().fill(Color.accent).frame(width: 1.5)
                            .offset(x: geo.size.width * frac)
                    }
                }
        }
    }

    private var lapStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(laps) { l in
                        let on = l.id == lapId
                        Button {
                            lapId = l.id
                            cursor = 0
                        } label: {
                            Text(l.id == analysis.bestLapId ? "★ \(l.label)" : l.label)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(on ? Color.black : Color.white.opacity(l.isTimed ? 0.85 : 0.5))
                                .frame(width: 64, height: 32)
                                .background(on ? AnyShapeStyle(Color.accent) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(l.id)
                    }
                }
                .padding(.horizontal, 28)
            }
            .mask(HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 36)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            })
            .padding(.horizontal, -16)
            .onAppear { proxy.scrollTo(lapId, anchor: .center) }
            .onChange(of: lapId) { withAnimation { proxy.scrollTo(lapId, anchor: .center) } }
        }
        .frame(height: 32)
    }

    private var playBar: some View {
        HStack(spacing: 12) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            GeometryReader { geo in
                let frac = range.count > 1 ? cursor / Double(range.count - 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(Color.accent).frame(width: geo.size.width * frac, height: 4)
                    Circle().fill(Color.white).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.accent, lineWidth: 3))
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
            .frame(height: 40)
            Text(RunFormat.time(cursor / SessionAnalysis.hz))
                .font(.numeral(17)).foregroundStyle(.white)
                .frame(width: 64, alignment: .trailing)
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
