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
        var obdHz: Double = 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = uptimeNow()
            let live = readLive(now: now)
            let elapsed = model.recording.startedAt.map { context.date.timeIntervalSince($0) } ?? 0

            Group {
                if verticalSizeClass == .compact {
                    landscape(live: live, elapsed: elapsed)
                } else {
                    portrait(live: live, elapsed: elapsed)
                }
            }
            .background(Color.black)
            .onChange(of: GSample(lat: live.latG ?? 0, long: live.longG ?? 0)) { _, sample in
                let combined = (sample.lat * sample.lat + sample.long * sample.long).squareRoot()
                peakG = max(peakG, combined)
                trail.append(CGPoint(x: sample.lat, y: -sample.long))
                if trail.count > 40 { trail.removeFirst(trail.count - 40) }
            }
        }
        .persistentSystemOverlays(.hidden)
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
        live.obdHz = model.bus.obdHz(now: now)
        return live
    }

    // MARK: Portrait

    private func portrait(live: Live, elapsed: TimeInterval) -> some View {
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

            SessionButton(isRecording: true, elapsed: elapsed)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: Landscape

    private func landscape(live: Live, elapsed: TimeInterval) -> some View {
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
                SessionButton(isRecording: true, compact: true, elapsed: elapsed)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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
