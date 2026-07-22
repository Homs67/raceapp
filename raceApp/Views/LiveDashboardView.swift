//
//  LiveDashboardView.swift
//  raceApp
//
//  Full-screen live dashboard while recording. Collapse via chevron or
//  swipe-down returns to Sessions + mini-player; recording continues.
//

import SwiftUI
import SessionKit
import ObdKit
import CoreLocation

/// Large orange circular Start used on the Sessions idle surface.
struct SessionStartButton: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    var size: CGFloat = 96

    var body: some View {
        Button {
            model.startRecording(metricUnits: metric)
        }         label: {
            Text("START")
                .font(.numeral(size * 0.32, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Color.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Start")
    }
}

/// Circular red Stop used on the expanded dashboard and mini-player.
struct SessionStopButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 64

    var body: some View {
        Button {
            model.stopRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.recordRed)
                    .frame(width: size, height: size)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.black)
                    .frame(width: size * 0.28, height: size * 0.28)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Stop Recording")
    }
}

enum SessionElapsedFormat {
    static func format(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Banner / wireframe style: always `HH:MM:SS`.
    static func formatLong(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Recording dashboard

struct LiveDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("useMetricUnits") private var metric = false
    @AppStorage("shiftEnabled") private var shiftEnabled = false
    @AppStorage("shiftRPM") private var shiftRPM: Double = 5500

    var onCollapse: () -> Void = {}

    @State private var peakG: Double = 0
    @State private var trail: [CGPoint] = []
    @State private var dragOffset: CGFloat = 0
    @State private var cameraFrontIsPrimary = false
    @AppStorage("dashboardFace") private var face = 0

    private static let faceCount = 5

    private var indicator: ShiftIndicator {
        ShiftIndicator(enabled: shiftEnabled, shiftRPM: shiftRPM)
    }

    private func recordingHealthBanner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.cardGray)
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
            let isCameraFace = face == 4

            ZStack {
                VStack(spacing: 0) {
                    if !isCameraFace {
                        collapseChrome
                        healthBanners
                    }

                    TabView(selection: $face) {
                        ForEach(0..<Self.faceCount, id: \.self) { i in
                            faceView(i, live: live, landscape: isLandscape)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.2), value: face)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isCameraFace {
                        bottomBar(elapsed: elapsed, landscape: isLandscape)
                    }
                }

                // Camera face: full-bleed preview with chrome + bottom fade overlaid.
                if isCameraFace {
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            VStack(spacing: 0) {
                                collapseChrome
                                healthBanners
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .allowsHitTesting(false)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: geo.size.height * 0.5)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)

                            bottomBar(elapsed: elapsed, landscape: isLandscape)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .background(Color.black)
            .offset(y: max(0, dragOffset))
            .onAppear {
                if face < 0 || face >= Self.faceCount { face = 0 }
                #if DEBUG
                if let i = CommandLine.arguments.firstIndex(of: "-dash-face"),
                   i + 1 < CommandLine.arguments.count, let f = Int(CommandLine.arguments[i + 1]),
                   (0..<Self.faceCount).contains(f) {
                    face = f
                }
                #endif
            }
            .onChange(of: GSample(lat: live.latG ?? 0, long: live.longG ?? 0)) { _, sample in
                let combined = (sample.lat * sample.lat + sample.long * sample.long).squareRoot()
                peakG = max(peakG, combined)
                trail.append(CGPoint(x: sample.lat, y: -sample.long))
                if trail.count > 40 { trail.removeFirst(trail.count - 40) }
            }
        }
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var healthBanners: some View {
        if model.recording.samplesMayBePaused {
            recordingHealthBanner(
                icon: "exclamationmark.triangle.fill",
                text: "GPS went quiet — unlock to resume capture",
                color: .yellow)
        } else if model.camera.uiStatus == .on, face != 4 {
            recordingHealthBanner(
                icon: "camera.fill",
                text: "Keep the screen on while camera is recording",
                color: .green)
        } else if model.forceScreenAwakeForSession {
            recordingHealthBanner(
                icon: "sun.max.fill",
                text: "Screen staying awake — allow Always Location to lock safely",
                color: .accent)
        }
    }

    private var collapseChrome: some View {
        Capsule()
            .fill(Color.mutedWeak)
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onCollapse)
            .gesture(collapseDrag)
            .accessibilityLabel("Collapse dashboard")
            .accessibilityAddTraits(.isButton)
    }

    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                let shouldCollapse = value.translation.height > 120 || value.predictedEndTranslation.height > 220
                withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                if shouldCollapse { onCollapse() }
            }
    }

    // MARK: - Faces (swipe left/right)

    @ViewBuilder
    private func faceView(_ index: Int, live: Live, landscape: Bool) -> some View {
        switch index {
        case 1: gforceFace(live: live, landscape: landscape)
        case 2: trackMapFace(live: live, landscape: landscape)
        case 3: lapFace(landscape: landscape)
        case 4: cameraFace(landscape: landscape)
        default:
            if landscape { primaryLandscape(live: live) } else { primaryPortrait(live: live) }
        }
    }

    /// Full-bleed rear preview with front PiP (top-leading) while camera is ON.
    /// Tap the PiP to spring-swap which camera is primary.
    private func cameraFace(landscape: Bool) -> some View {
        Group {
            if model.camera.isCapturing, let rear = model.camera.rearPreviewLayer {
                DualCameraPreviewView(
                    rearLayer: rear,
                    frontLayer: model.camera.frontPreviewLayer,
                    landscape: landscape,
                    frontIsPrimary: $cameraFrontIsPrimary
                )
                .onChange(of: model.camera.usesMultiCam) { _, multi in
                    if !multi { cameraFrontIsPrimary = false }
                }
                .onChange(of: model.camera.isCapturing) { _, capturing in
                    if !capturing { cameraFrontIsPrimary = false }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(Color.mutedWeak)
                    Text(model.camera.uiStatus == .unavailable
                         ? "Camera unavailable"
                         : "Turn camera ON to preview")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Use the camera control below")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { cameraFrontIsPrimary = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityLabel("Camera preview")
    }

    /// Persistent bottom bar: page dots + 3-column chrome (camera | stop | close).
    private func bottomBar(elapsed: TimeInterval, landscape: Bool) -> some View {
        let dots = HStack(spacing: 7) {
            ForEach(0..<Self.faceCount, id: \.self) { i in
                Circle()
                    .fill(i == face ? Color.accent : Color.mutedWeak)
                    .frame(width: 7, height: 7)
            }
        }
        let stopSize: CGFloat = landscape ? 52 : 64
        let sideSize: CGFloat = landscape ? 40 : 48
        let cameraStatus = model.camera.uiStatus

        let cameraButton = Button {
            model.toggleSessionCamera()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: landscape ? 15 : 17, weight: .semibold))
                    .foregroundStyle(cameraStatus == .on ? Color.black
                                     : cameraStatus == .unavailable ? Color.mutedWeak
                                     : Color.muted)
                    .frame(width: sideSize, height: sideSize)
                    .background {
                        if cameraStatus == .on {
                            Circle().fill(Color.white)
                        } else {
                            Circle().stroke(
                                cameraStatus == .unavailable ? Color.mutedWeak.opacity(0.5) : Color.mutedWeak,
                                lineWidth: 1.5)
                        }
                    }
                Text(cameraStatus == .on ? "ON" : cameraStatus == .off ? "OFF" : "N/A")
                    .font(.system(size: landscape ? 10 : 11, weight: .semibold))
                    .foregroundStyle(cameraStatus == .on ? Color.white
                                     : cameraStatus == .unavailable ? Color.mutedWeak
                                     : Color.muted)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera \(cameraStatus == .on ? "on" : cameraStatus == .off ? "off" : "unavailable")")

        let closeButton = Button(action: onCollapse) {
            Image(systemName: "xmark")
                .font(.system(size: landscape ? 15 : 17, weight: .semibold))
                .foregroundStyle(Color.muted)
                .frame(width: sideSize, height: sideSize)
                .background(Circle().stroke(Color.mutedWeak, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close dashboard")

        let timer = Text(SessionElapsedFormat.format(elapsed))
            .font(.numeral(landscape ? 15 : 17, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.recordRed)

        let controls = HStack(alignment: .top, spacing: 0) {
            cameraButton
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 8) {
                SessionStopButton(size: stopSize)
                timer
            }
            .frame(maxWidth: .infinity)

            closeButton
                .frame(maxWidth: .infinity)
                .padding(.top, 0)
        }

        return Group {
            if landscape {
                VStack(spacing: 0) {
                    dots
                    controls
                        .padding(.top, 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            } else {
                // Portrait: reserve a fixed chrome strip; dashboard uses the rest.
                VStack(spacing: 0) {
                    dots
                    controls
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(height: 158)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
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
