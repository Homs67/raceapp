//
//  RecordView.swift
//  raceApp
//
//  Home tab, restyled to the iOS Fitness aesthetic (pure black, rounded
//  #1F1F1F cards, big bold titles) with the orange/white/red palette.
//  Idle screen = status card + START hero; recording = live dashboard.
//

import SwiftUI
import SessionKit
import ObdKit
import CoreLocation

struct RecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.recording.isRecording {
                DashboardView()
            } else {
                IdleRecordView()
            }
        }
        .toolbar(model.recording.isRecording ? .hidden : .visible, for: .tabBar)
    }
}

// MARK: - Idle (Fitness style)

private struct IdleRecordView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(date: context.date)

                Spacer()
                idleHero
                Spacer()

                SessionButton(isRecording: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .background(Color.black)
        }
    }

    private func header(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Record")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.system(size: 15))
                .foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var idleHero: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.mutedWeak)
            Text("Ready to record")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("Every channel — GPS, motion, and OBD — is captured the moment you start.")
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shared start/stop control: identical shape and size in both states —
/// only the fill color and label change. Orange "Start Session" → red-filled
/// "Stop Recording" (R1.1–R1.3).
struct SessionButton: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    var isRecording: Bool
    /// Landscape uses a narrower, intrinsic-width button; portrait/idle fill the row.
    var compact: Bool = false
    /// Elapsed recording time, shown on the Stop button (replaces the REC chip).
    var elapsed: TimeInterval? = nil

    private var label: String {
        guard isRecording else { return "Start Session" }
        if let elapsed { return "Stop Recording · \(Self.format(elapsed))" }
        return "Stop Recording"
    }

    var body: some View {
        Button {
            if isRecording {
                model.stopRecording()
            } else {
                model.startRecording(metricUnits: metric)
            }
        } label: {
            Text(label)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isRecording ? Color.recordRed : .white)
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? 26 : 0)
                .frame(height: compact ? 46 : 56)
                .background(background)
                .contentShape(RoundedRectangle(cornerRadius: compact ? 14 : 16))
        }
        .buttonStyle(PressableButtonStyle())
    }

    static func format(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // Start = solid orange fill, white text.
    // Stop  = red outline only, no fill, red text — high contrast on black.
    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 14 : 16)
        if isRecording {
            shape.stroke(Color.recordRed, lineWidth: 1.5)
        } else {
            shape.fill(Color.accent)
        }
    }
}

// MARK: - Recording dashboard

private struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage("shiftEnabled") private var shiftEnabled = false
    @AppStorage("shiftRPM") private var shiftRPM: Double = 5500

    @State private var peakG: Double = 0
    @State private var trail: [CGPoint] = []
    @AppStorage("dashboardFace") private var face = 0

    private static let faceCount = 6

    private var indicator: ShiftIndicator {
        ShiftIndicator(enabled: shiftEnabled, shiftRPM: shiftRPM)
    }

    private func rpmColor(_ rpm: Double?) -> Color {
        switch indicator.phase(rpm: rpm) {
        case .shift: return .recordRed
        case .approach(let progress) where progress >= 0.75: return .accent
        default: return (rpm ?? 0) >= 6800 ? .recordRed : .textPrimary
        }
    }

    private func tachFill(_ rpm: Double?) -> Color? {
        switch indicator.phase(rpm: rpm) {
        case .shift: return .recordRed
        case .approach(let progress) where progress >= 0.5: return .accent
        default: return nil
        }
    }

    private func rpmScale(_ rpm: Double?) -> CGFloat {
        indicator.phase(rpm: rpm) == .shift ? 1.04 : 1.0
    }

    private struct Live {
        var rpm: Double?
        var speedDisplay: Double?
        var speedMps: Double?
        var throttle: Double?
        var gear: Int?
        var latG: Double?
        var longG: Double?
        var gCalibrated = false
        var combinedG: Double?
        var altitude: Double?
        var yawDegPerS: Double?
        var heading: Double?
        var gpsAccuracy: Double?
        var gpsLat: Double?
        var gpsLon: Double?
        var obdHz: Double = 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = uptimeNow()
            let live = readLive(now: now)
            let elapsed = model.recording.startedAt.map { context.date.timeIntervalSince($0) } ?? 0

            let isLandscape = verticalSizeClass == .compact

            VStack(spacing: 0) {
                TabView(selection: $face) {
                    ForEach(0..<Self.faceCount, id: \.self) { i in
                        faceView(i, live: live, landscape: isLandscape)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.2), value: face)

                bottomBar(elapsed: elapsed, landscape: isLandscape)
            }
            .background(Color.black)
            #if DEBUG
            .onAppear {
                if let i = CommandLine.arguments.firstIndex(of: "-dash-face"),
                   i + 1 < CommandLine.arguments.count, let f = Int(CommandLine.arguments[i + 1]) {
                    face = f
                }
            }
            #endif
            .onChange(of: GSample(lat: live.latG ?? 0, long: live.longG ?? 0)) { _, sample in
                let combined = (sample.lat * sample.lat + sample.long * sample.long).squareRoot()
                peakG = max(peakG, combined)
                trail.append(CGPoint(x: sample.lat, y: -sample.long))
                if trail.count > 40 { trail.removeFirst(trail.count - 40) }
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Faces (swipe left/right)

    @ViewBuilder
    private func faceView(_ index: Int, live: Live, landscape: Bool) -> some View {
        switch index {
        case 1: gforceFace(live: live, landscape: landscape)
        case 2: trackMapFace(live: live, landscape: landscape)
        case 3: lapFace(landscape: landscape)
        case 4: dragFace(landscape: landscape)
        case 5: healthFace(now: uptimeNow(), landscape: landscape)
        default:
            if landscape { primaryLandscape(live: live) } else { primaryPortrait(live: live) }
        }
    }

    /// Persistent bottom bar: page dots + the stop control, in every face.
    private func bottomBar(elapsed: TimeInterval, landscape: Bool) -> some View {
        let dots = HStack(spacing: 7) {
            ForEach(0..<Self.faceCount, id: \.self) { i in
                Circle()
                    .fill(i == face ? Color.accent : Color.mutedWeak)
                    .frame(width: 7, height: 7)
            }
        }
        return Group {
            if landscape {
                HStack(spacing: 16) {
                    dots
                    Spacer()
                    SessionButton(isRecording: true, compact: true, elapsed: elapsed)
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    dots
                    SessionButton(isRecording: true, elapsed: elapsed)
                }
                .padding(.horizontal, 22).padding(.bottom, 16).padding(.top, 6)
            }
        }
    }

    // MARK: G-force face

    private func gforceFace(live: Live, landscape: Bool) -> some View {
        let meter = GMeterView(latG: live.latG, longG: live.longG, peakG: peakG, trail: trail)
        return VStack(spacing: landscape ? 8 : 18) {
            HStack {
                microLabel("G-FORCE")
                Spacer()
                if !live.gCalibrated {
                    Text("CALIBRATING…")
                        .font(.system(size: 9, weight: .medium)).kerning(1)
                        .foregroundStyle(Color.mutedWeak)
                }
            }
            meter
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
            HStack(spacing: 28) {
                gStat("LAT", live.latG)
                gStat("LONG", live.longG)
                gStat("COMBINED", live.combinedG)
                gStat("PEAK", peakG)
            }
        }
        .padding(.horizontal, landscape ? 24 : 22)
        .padding(.top, landscape ? 10 : 8)
    }

    private func gStat(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.numeral(22, weight: .semibold))
                .foregroundStyle(value == nil ? Color.mutedWeak : Color.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .semibold)).kerning(1)
                .foregroundStyle(Color.muted)
        }
    }

    // MARK: Track-map face

    @ViewBuilder
    private func trackMapFace(live: Live, landscape: Bool) -> some View {
        if let track = model.metrics.track {
            let position = (live.gpsLat).flatMap { lat in live.gpsLon.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
            VStack(alignment: .leading, spacing: landscape ? 6 : 12) {
                HStack {
                    microLabel(track.name.uppercased())
                    Spacer()
                    Text(String(format: "%.2f mi", track.lengthMiles))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color.muted)
                }
                TrackMapCanvas(track: track, position: position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 28) {
                    metricBlock(value: live.speedDisplay.map { String(Int($0)) }, label: "SPEED",
                                size: landscape ? 44 : 56, color: .textPrimary,
                                unit: UnitsFormatter(metric: metric).speedUnit)
                    metricBlock(value: live.gear.map(String.init), label: "GEAR",
                                size: landscape ? 44 : 56, color: .accent)
                }
            }
            .padding(.horizontal, landscape ? 24 : 22)
            .padding(.top, landscape ? 10 : 8)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "map").font(.system(size: 40)).foregroundStyle(Color.mutedWeak)
                Text("No track matched").font(.headline).foregroundStyle(Color.muted)
                Text("The map appears on known tracks.")
                    .font(.caption).foregroundStyle(Color.mutedWeak)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct GSample: Equatable {
        let lat: Double
        let long: Double
    }

    private func readLive(now: TimeInterval) -> Live {
        let snapshot = model.bus.snapshot()
        let units = UnitsFormatter(metric: metric)
        var live = Live()
        live.rpm = snapshot.fresh(.obd(.rpm), now: now, maxAge: 2)
        live.throttle = snapshot.fresh(.obd(.throttle), now: now, maxAge: 2)

        if let obdKmh = snapshot.fresh(.obd(.speed), now: now, maxAge: 2) {
            live.speedMps = obdKmh / 3.6
            live.speedDisplay = units.speed(fromKmh: obdKmh)
        } else if let gpsMps = snapshot.fresh(.gpsSpeed, now: now, maxAge: 3) {
            live.speedMps = gpsMps
            live.speedDisplay = units.speed(fromMps: gpsMps)
        }
        if let rpm = live.rpm, let speedMps = live.speedMps {
            live.gear = model.gearEstimator.gear(rpm: rpm, speedMps: speedMps)
        }
        // Prefer auto-calibrated car-frame G; fall back to raw device axes
        // until leveling + alignment complete (flagged so the UI stays honest).
        if let lat = snapshot.fresh(.carLatG, now: now, maxAge: 1),
           let long = snapshot.fresh(.carLongG, now: now, maxAge: 1) {
            live.latG = lat
            live.longG = long
            live.gCalibrated = true
        } else {
            live.latG = snapshot.fresh(.imuAccelX, now: now, maxAge: 1)
            live.longG = snapshot.fresh(.imuAccelY, now: now, maxAge: 1)
        }
        if let lat = live.latG, let long = live.longG {
            live.combinedG = (lat * lat + long * long).squareRoot()
        }
        live.altitude = snapshot.fresh(.gpsAltitude, now: now, maxAge: 10)
        live.yawDegPerS = snapshot.fresh(.imuYawRate, now: now, maxAge: 1).map { $0 * 180 / .pi }
        live.heading = snapshot.fresh(.gpsCourse, now: now, maxAge: 10)
        live.gpsAccuracy = snapshot.fresh(.gpsHorizontalAccuracy, now: now, maxAge: 10)
        live.gpsLat = snapshot.fresh(.gpsLatitude, now: now, maxAge: 5)
        live.gpsLon = snapshot.fresh(.gpsLongitude, now: now, maxAge: 5)
        live.obdHz = model.bus.obdHz(now: now)
        return live
    }

    // MARK: Portrait

    private func primaryPortrait(live: Live) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("OBD \(String(format: "%.0f", live.obdHz)) Hz")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Color.muted)
                Text(live.gpsAccuracy.map { "GPS ±\(Int($0)) m" } ?? "GPS —")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Color.muted)
                Spacer()
            }

            if shiftEnabled {
                ShiftLightBar(indicator: indicator, rpm: live.rpm)
            }
            TachBar(rpm: live.rpm, fillOverride: tachFill(live.rpm))

            VStack(alignment: .leading, spacing: 0) {
                bigNumeral(live.rpm.map { String(Int($0)) }, size: 130, color: rpmColor(live.rpm))
                    .scaleEffect(rpmScale(live.rpm), anchor: .leading)
                    .animation(.easeOut(duration: 0.12), value: rpmScale(live.rpm))
                microLabel("RPM")
            }

            HStack(alignment: .top, spacing: 48) {
                metricBlock(value: live.gear.map(String.init) ?? (live.speedMps ?? 0 > 2 ? "N" : nil),
                            label: "GEAR", size: 88, color: .accent)
                metricBlock(value: live.speedDisplay.map { String(Int($0)) },
                            label: "SPEED", size: 88, color: .textPrimary,
                            unit: UnitsFormatter(metric: metric).speedUnit)
            }

            ThrottleBar(percent: live.throttle)

            Spacer(minLength: 8)

            HStack(alignment: .center, spacing: 20) {
                GMeterView(latG: live.latG, longG: live.longG, peakG: peakG, trail: trail)
                    .frame(width: 176, height: 176)
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.combinedG.map { String(format: "%.2f", $0) } ?? "—")
                        .font(.numeral(38, weight: .semibold))
                        .foregroundStyle(live.combinedG == nil ? Color.mutedWeak : Color.textPrimary)
                    + Text(" g")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.muted)
                    Text("PEAK \(String(format: "%.2f", peakG)) g")
                        .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Color.mutedStrong)
                    if !live.gCalibrated {
                        Text("CALIBRATING…")
                            .font(.system(size: 9, weight: .medium)).kerning(1)
                            .foregroundStyle(Color.mutedWeak)
                    }
                }
                Spacer()
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    // MARK: Landscape

    private func primaryLandscape(live: Live) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                if shiftEnabled {
                    ShiftLightBar(indicator: indicator, rpm: live.rpm, height: 6)
                }
                TachBar(rpm: live.rpm, height: 28, segmented: true, fillOverride: tachFill(live.rpm))
                HStack {
                    microLabel("RPM ×1000")
                    Spacer()
                    Text("REDLINE 7.5K")
                        .font(.system(size: 9, weight: .semibold)).kerning(1.5)
                        .foregroundStyle(Color.recordRed.opacity(0.85))
                }
            }

            HStack(alignment: .top, spacing: 36) {
                bigNumeral(live.rpm.map { String(Int($0)) }, size: 150, color: rpmColor(live.rpm))
                    .frame(minWidth: 300, alignment: .leading)
                bigNumeral(live.gear.map(String.init) ?? "N", size: 120, color: .accent)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bigNumeral(live.speedDisplay.map { String(Int($0)) }, size: 96)
                        Text(UnitsFormatter(metric: metric).speedUnit)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.muted)
                    }
                    ThrottleBar(percent: live.throttle, barWidth: 180)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 16) {
                GMeterView(latG: live.latG, longG: live.longG, peakG: peakG,
                           trail: trail, pointsPerG: 32)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.combinedG.map { String(format: "%.2f g", $0) } ?? "—")
                        .font(.system(size: 18, weight: .medium)).monospacedDigit()
                        .foregroundStyle(live.combinedG == nil ? Color.mutedWeak : Color.textPrimary)
                    Text(live.gCalibrated ? "PEAK \(String(format: "%.2f", peakG))" : "CALIBRATING…")
                        .font(.system(size: 9, weight: .semibold)).kerning(1)
                        .foregroundStyle(live.gCalibrated ? Color.mutedStrong : Color.mutedWeak)
                }
                Divider().overlay(Color.white.opacity(0.1)).frame(height: 40)
                landscapeStat("ALT", live.altitude.map {
                    let units = UnitsFormatter(metric: metric)
                    return "\(Int(units.shortDistance(fromMeters: $0))) \(units.shortDistanceUnit)"
                })
                landscapeStat("YAW", live.yawDegPerS.map { String(format: "%.0f°/s", $0) })
                landscapeStat("HDG", live.heading.map { String(format: "%03.0f°", $0) })
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    // MARK: Lap-time face

    private func lapFace(landscape: Bool) -> some View {
        let s = model.metrics.lapState
        return VStack(alignment: .leading, spacing: landscape ? 8 : 18) {
            HStack {
                microLabel("LAP \(s.completedLaps + 1)")
                Spacer()
                if model.metrics.track == nil {
                    Text("NO TRACK").font(.system(size: 9, weight: .medium)).kerning(1)
                        .foregroundStyle(Color.mutedWeak)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                bigNumeral(Self.lapString(s.currentLapTime), size: landscape ? 92 : 108)
                microLabel("CURRENT")
            }
            HStack(spacing: 44) {
                lapStat("LAST", s.lastLapTime)
                lapStat("BEST", s.bestLapTime, highlight: true)
            }
            if !s.lapTimes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(s.lapTimes.suffix(landscape ? 3 : 5).enumerated().reversed()), id: \.offset) { i, lap in
                        HStack {
                            Text("L\(i + 1)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                            Spacer()
                            Text(Self.lapString(lap)).font(.numeral(16, weight: .medium))
                                .foregroundStyle(lap == s.bestLapTime ? Color.accent : Color.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: 260)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, landscape ? 24 : 22).padding(.top, landscape ? 10 : 8)
    }

    private func lapStat(_ label: String, _ value: TimeInterval?, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.lapString(value)).font(.numeral(30, weight: .semibold))
                .foregroundStyle(value == nil ? Color.mutedWeak : (highlight ? Color.accent : Color.textPrimary))
            Text(label).font(.system(size: 9, weight: .semibold)).kerning(1).foregroundStyle(Color.muted)
        }
    }

    static func lapString(_ t: TimeInterval?) -> String {
        guard let t else { return "—:—" }
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    // MARK: Drag face

    private func dragFace(landscape: Bool) -> some View {
        let r = model.metrics.dragRun, b = model.metrics.dragBest
        return VStack(alignment: .leading, spacing: landscape ? 10 : 22) {
            HStack {
                microLabel("ACCELERATION")
                Spacer()
                if r.launching {
                    Text("● LAUNCH").font(.system(size: 10, weight: .semibold)).kerning(1)
                        .foregroundStyle(Color.recordRed)
                }
            }
            dragRow("0–60 MPH", r.zeroToSixty, b.zeroToSixty)
            dragRow("0–100 MPH", r.zeroToHundred, b.zeroToHundred)
            dragRow("¼ MILE", r.quarterMile, b.quarterMile,
                    trapKmh: r.quarterMileTrapKmh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, landscape ? 24 : 22).padding(.top, landscape ? 10 : 8)
    }

    private func dragRow(_ label: String, _ value: TimeInterval?, _ best: TimeInterval?,
                         trapKmh: Double? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Color.muted)
                if let best { Text("BEST \(String(format: "%.2f", best))s")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mutedWeak) }
            }
            Spacer()
            if let trapKmh, value != nil {
                Text("\(Int(UnitsFormatter(metric: metric).speed(fromKmh: trapKmh))) \(UnitsFormatter(metric: metric).speedUnit)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted).padding(.trailing, 10)
            }
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.numeral(34, weight: .semibold))
                .foregroundStyle(value == nil ? Color.mutedWeak : Color.textPrimary)
            + Text(value != nil ? " s" : "").font(.system(size: 15)).foregroundStyle(Color.muted)
        }
    }

    // MARK: Vehicle-health face

    private func healthFace(now: TimeInterval, landscape: Bool) -> some View {
        let snap = model.bus.snapshot()
        func v(_ ch: ChannelId, _ maxAge: TimeInterval = 8) -> Double? { snap.fresh(ch, now: now, maxAge: maxAge) }
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: landscape ? 8 : 16) {
            microLabel("VEHICLE HEALTH")
            LazyVGrid(columns: cols, alignment: .leading, spacing: landscape ? 10 : 18) {
                healthStat("COOLANT", v(.obd(.coolantTemp)), "°C", warn: v(.obd(.coolantTemp)).map { $0 > 110 } ?? false)
                healthStat("OIL", v(.obd(.oilTemp)), "°C", warn: v(.obd(.oilTemp)).map { $0 > 125 } ?? false)
                healthStat("INTAKE AIR", v(.obd(.intakeAirTemp)), "°C")
                healthStat("FUEL", v(.obd(.fuelLevel)), "%", warn: v(.obd(.fuelLevel)).map { $0 < 12 } ?? false)
                healthStat("BATTERY", v(.obd(.controlModuleVoltage)).map { $0 / 1000 }, "V")
                healthStat("ENGINE LOAD", v(.obd(.engineLoad)), "%")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, landscape ? 24 : 22).padding(.top, landscape ? 10 : 8)
    }

    private func healthStat(_ label: String, _ value: Double?, _ unit: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(Int($0.rounded())) } ?? "—")
                    .font(.numeral(38, weight: .semibold))
                    .foregroundStyle(value == nil ? Color.mutedWeak : (warn ? Color.recordRed : Color.textPrimary))
                Text(unit).font(.system(size: 14)).foregroundStyle(Color.muted)
            }
            Text(label).font(.system(size: 10, weight: .semibold)).kerning(1).foregroundStyle(Color.muted)
        }
    }

    // MARK: Pieces

    private func landscapeStat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold)).kerning(1)
                .foregroundStyle(Color.muted)
            Text(value ?? "—")
                .font(.numeral(20, weight: .medium))
                .foregroundStyle(value == nil ? Color.mutedWeak : Color.textPrimary)
        }
    }

    private func metricBlock(value: String?, label: String, size: CGFloat,
                             color: Color, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                bigNumeral(value, size: size, color: color)
                if let unit, value != nil {
                    Text(unit)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.muted)
                }
            }
            microLabel(label)
        }
    }

    private func bigNumeral(_ text: String?, size: CGFloat, color: Color = .textPrimary) -> some View {
        Text(text ?? "—")
            .font(.numeral(size, weight: text == nil ? .medium : .semibold))
            .foregroundStyle(text == nil ? Color.mutedWeak : color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func microLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).kerning(1.5)
            .foregroundStyle(Color.muted)
    }
}

/// Subtle press feedback for the big buttons.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

func uptimeNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
