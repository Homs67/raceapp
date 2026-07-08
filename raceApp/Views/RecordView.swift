//
//  RecordView.swift
//  raceApp
//
//  Home tab: idle screen with the big START button (design screen 1),
//  live dashboard while recording (screens 2–3), both orientations.
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

// MARK: - Shared status chips

struct ConnectionChipsRow: View {
    @Environment(AppModel.self) private var model
    var snapshot: [ChannelId: TelemetryReading]
    var now: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(
                text: "ADAPTER",
                dotColor: model.connection.adapterLinkUp ? .okGreen : .white.opacity(0.3))
            StatusChip(
                text: model.connection.carLinkUp ? "CAR" : "CAR —",
                dotColor: model.connection.carLinkUp ? .okGreen : .white.opacity(0.3))
            if model.connection.carLinkUp {
                StatusChip(text: "OBD \(String(format: "%.0f", model.bus.obdHz(now: now))) Hz")
            }
            if let accuracy = snapshot.fresh(.gpsHorizontalAccuracy, now: now, maxAge: 10) {
                StatusChip(text: "GPS ±\(Int(accuracy)) m")
            } else {
                StatusChip(text: "GPS —")
            }
        }
    }
}

// MARK: - Idle (design screen 1)

private struct IdleRecordView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let now = uptimeNow()
            let snapshot = model.bus.snapshot()
            VStack(spacing: 0) {
                ConnectionChipsRow(snapshot: snapshot, now: now)
                    .padding(.top, 16)

                if !model.connection.carLinkUp {
                    noObdNotice.padding(.top, 14)
                }

                Spacer()
                startButton
                VStack(spacing: 6) {
                    Text("START SESSION")
                        .font(.numeral(20, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("No setup, no modes. Every channel is recorded.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .padding(.top, 22)
                Spacer()

                Text("Keeps recording with the screen locked, in the background, or during a phone call.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedWeak)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgScreen)
        }
    }

    private var startButton: some View {
        Button {
            model.startRecording(metricUnits: metric)
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.recordRed.opacity(0.5), lineWidth: 4)
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(Color.recordRed)
                    .frame(width: 112, height: 112)
                Text("START")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var noObdNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("No OBD")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.warnAmber)
            Text("— engine channels won't be recorded. GPS, G-meter, barometer and device health still capture. Set up in Connection.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(12)
        .background(Color.warnAmber.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.warnAmber.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 22)
    }
}

// MARK: - Recording dashboard (design screens 2–3)

private struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("useMetricUnits") private var metric = false

    @State private var peakG: Double = 0
    @State private var trail: [CGPoint] = []

    private struct Live {
        var rpm: Double?
        var speedDisplay: Double?
        var speedMps: Double?
        var throttle: Double?
        var gear: Int?
        var latG: Double?
        var longG: Double?
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
        live.latG = snapshot.fresh(.imuAccelX, now: now, maxAge: 1)
        live.longG = snapshot.fresh(.imuAccelY, now: now, maxAge: 1)
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

    // MARK: Portrait (design screen 2)

    private func portrait(live: Live, elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                recChip(elapsed: elapsed)
                StatusChip(text: "OBD \(String(format: "%.0f", live.obdHz)) Hz")
                StatusChip(text: live.gpsAccuracy.map { "GPS ±\(Int($0)) m" } ?? "GPS —")
            }

            TachBar(rpm: live.rpm)
            VStack(alignment: .leading, spacing: 2) {
                bigNumeral(live.rpm.map { String(Int($0)) }, size: 124,
                           color: (live.rpm ?? 0) >= 6800 ? .recordRed : .textPrimary)
                microLabel("RPM")
            }

            HStack(alignment: .top, spacing: 52) {
                VStack(alignment: .leading, spacing: 2) {
                    bigNumeral(live.gear.map(String.init) ?? (live.speedMps ?? 0 > 2 ? "N" : nil),
                               size: 84, color: .accentCyan)
                    microLabel("GEAR")
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bigNumeral(live.speedDisplay.map { String(Int($0)) }, size: 84)
                        Text(UnitsFormatter(metric: metric).speedUnit)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    microLabel("SPEED")
                }
            }

            ThrottleBar(percent: live.throttle)

            HStack(alignment: .center, spacing: 18) {
                GMeterView(latG: live.latG, longG: live.longG, peakG: peakG, trail: trail)
                    .frame(width: 188, height: 188)
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.combinedG.map { String(format: "%.2f g", $0) } ?? "—")
                        .font(.system(size: 30, weight: .medium)).monospacedDigit()
                        .foregroundStyle(live.combinedG == nil ? Color.mutedWeak : Color.textPrimary)
                    Text("PEAK \(String(format: "%.2f", peakG)) g")
                        .font(.microLabel(10)).kerning(1)
                        .foregroundStyle(Color.warnAmber)
                }
            }
            .frame(maxHeight: .infinity)

            stopButton(elapsed: elapsed)
        }
        .padding(22)
    }

    // MARK: Landscape (design screen 3 — the designed-for layout)

    private func landscape(live: Live, elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                TachBar(rpm: live.rpm, height: 30, segmented: true)
                HStack {
                    microLabel("RPM ×1000")
                    Spacer()
                    Text("REDLINE 7.5K")
                        .font(.microLabel(9)).kerning(1.5)
                        .foregroundStyle(Color.recordRed.opacity(0.8))
                }
            }

            HStack(alignment: .top, spacing: 36) {
                bigNumeral(live.rpm.map { String(Int($0)) }, size: 150,
                           color: (live.rpm ?? 0) >= 6800 ? .recordRed : .textPrimary)
                    .frame(minWidth: 300, alignment: .leading)
                bigNumeral(live.gear.map(String.init) ?? "N", size: 120, color: .accentCyan)
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bigNumeral(live.speedDisplay.map { String(Int($0)) }, size: 96)
                        Text(UnitsFormatter(metric: metric).speedUnit)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.white.opacity(0.45))
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
                    Text("PEAK \(String(format: "%.2f", peakG))")
                        .font(.microLabel(9)).kerning(1)
                        .foregroundStyle(Color.warnAmber)
                }
                Divider().overlay(Color.cardBorder).frame(height: 40)
                landscapeStat("ALT", live.altitude.map {
                    let units = UnitsFormatter(metric: metric)
                    return "\(Int(units.shortDistance(fromMeters: $0))) \(units.shortDistanceUnit)"
                })
                landscapeStat("YAW", live.yawDegPerS.map { String(format: "%.0f°/s", $0) })
                landscapeStat("HDG", live.heading.map { String(format: "%03.0f°", $0) })
                Spacer()
                recChip(elapsed: elapsed)
                stopButtonCompact
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: Pieces

    private func landscapeStat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.microLabel(9)).kerning(1)
                .foregroundStyle(Color.muted)
            Text(value ?? "—")
                .font(.numeral(20, weight: .medium))
                .foregroundStyle(value == nil ? Color.mutedWeak : Color.textPrimary)
        }
    }

    private func recChip(elapsed: TimeInterval) -> some View {
        StatusChip(text: "REC \(formatElapsed(elapsed))",
                   dotColor: .recordRed,
                   tint: .recordRed,
                   background: Color.recordRed.opacity(0.15),
                   pulsing: true)
    }

    private func stopButton(elapsed: TimeInterval) -> some View {
        Button {
            model.stopRecording()
        } label: {
            Text("STOP · \(formatElapsed(elapsed))")
                .font(.system(size: 15, weight: .semibold))
                .kerning(1.5)
                .monospacedDigit()
                .foregroundStyle(Color.recordRed)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.recordRed.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var stopButtonCompact: some View {
        Button {
            model.stopRecording()
        } label: {
            Text("STOP")
                .font(.system(size: 13, weight: .semibold)).kerning(1.5)
                .foregroundStyle(Color.recordRed)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Color.recordRed.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
            .font(.microLabel(10)).kerning(2)
            .foregroundStyle(Color.muted)
    }

    private func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

func uptimeNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
