//
//  DriverInputWidgets.swift
//  raceApp
//
//  Steering angle and acceleration runs.
//

import SwiftUI
import SessionKit

/// Steering wheel angle from the CAN bus, + to the right.
struct SteeringWidget: View {
    let context: WidgetContext

    /// ND2 is roughly 2.6 turns lock to lock, so ±470°. Used only to scale
    /// the bar — the number itself is never clamped.
    private static let lock: Double = 470

    var body: some View {
        let angle = context.live.steering
        switch context.size {
        case .medium:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    WidgetValue(text: text(angle), context: context)
                    WidgetCaption(text: side(angle))
                }
                SteeringBar(angle: angle, lock: Self.lock)
                    .frame(height: 12)
            }
        default:
            WidgetValue(text: text(angle), context: context)
        }
    }

    private func text(_ angle: Double?) -> String {
        guard let angle else { return "—" }
        return String(Int(angle.rounded())) + "°"
    }

    private func side(_ angle: Double?) -> String {
        guard let angle, abs(angle) >= 5 else { return "centred" }
        return angle > 0 ? "right" : "left"
    }
}

/// Centre-zero bar: fills from the middle toward the lock the driver is
/// winding on, so a glance shows direction and how much.
private struct SteeringBar: View {
    let angle: Double?
    let lock: Double

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let fraction = min(1, abs(angle ?? 0) / lock)
            let width = half * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Rectangle().fill(Color.mutedWeak)
                    .frame(width: 1, height: geo.size.height)
                    .offset(x: half - 0.5)
                if let angle {
                    Capsule().fill(Color.accent)
                        .frame(width: max(2, width))
                        .offset(x: angle < 0 ? half - width : half)
                }
            }
        }
    }
}

/// Acceleration runs. Which figure it shows is a per-widget setting, because
/// 0–60 is the road benchmark, the quarter is the strip's, and nobody wants
/// all three competing for one cell.
struct DragWidget: View {
    let context: WidgetContext

    static let metricKey = "dragMetric"

    enum Metric: String, CaseIterable {
        case zeroToSixty = "0-60"
        case zeroToHundred = "0-100"
        case quarterMile = "quarter"

        var label: String {
            switch self {
            case .zeroToSixty: return "0–60 mph"
            case .zeroToHundred: return "0–100 mph"
            case .quarterMile: return "¼ mile"
            }
        }

        var title: String {
            switch self {
            case .zeroToSixty: return "0–60"
            case .zeroToHundred: return "0–100"
            case .quarterMile: return "¼ MILE"
            }
        }

        func value(_ run: DragMeter.Run) -> TimeInterval? {
            switch self {
            case .zeroToSixty: return run.zeroToSixty
            case .zeroToHundred: return run.zeroToHundred
            case .quarterMile: return run.quarterMile
            }
        }
    }

    private var metric: Metric {
        Metric(rawValue: context.placement.settings[Self.metricKey] ?? "") ?? .zeroToSixty
    }

    var body: some View {
        let run = context.live.dragRun
        let best = context.live.dragBest
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetCaption(text: run.launching ? "launching" : metric.title)
                    WidgetValue(text: seconds(metric.value(run)), context: context)
                }
                if let b = metric.value(best) {
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption(text: "best")
                        WidgetSecondaryValue(text: seconds(b), color: .white.opacity(0.5))
                    }
                }
                if metric == .quarterMile, let trap = best.quarterMileTrapKmh {
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption(text: "trap")
                        WidgetSecondaryValue(
                            text: String(Int(context.units.speed(fromKmh: trap).rounded())),
                            color: .white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }
        default:
            WidgetValue(text: seconds(metric.value(run) ?? metric.value(best)), context: context)
        }
    }

    private func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}

/// Distance covered since recording started.
struct DistanceWidget: View {
    let context: WidgetContext

    var body: some View {
        let d = context.units.distance(fromMeters: context.live.distanceMeters)
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetValue(text: String(format: "%.1f", d), context: context)
            WidgetCaption(text: context.units.distanceUnit)
        }
    }
}

/// Both links at a glance: what is feeding this dashboard right now.
struct LinksWidget: View {
    let context: WidgetContext

    var body: some View {
        let live = context.live
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 28) {
                link("RaceBox", up: live.raceBox != nil,
                     detail: live.raceBox.map { "\($0.satellites) sats · \($0.power.shortText)" } ?? "not linked",
                     warn: live.raceBox?.power.needsAttention == true)
                link("OBD-II", up: live.obdConnected,
                     detail: live.obdConnected ? (live.obdLive ? "live" : "no engine data") : "not linked")
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                dot("RB", up: live.raceBox != nil)
                dot("OBD", up: live.obdConnected)
            }
        }
    }

    private func link(_ name: String, up: Bool, detail: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetCaption(text: name)
            HStack(spacing: 8) {
                Circle().fill(up ? Color.deltaGreen : Color.toolbarRed)
                    .frame(width: 10, height: 10)
                Text(detail)
                    .font(.sofia(WidgetMetrics.minTextSize, .regular))
                    .foregroundStyle(warn ? Color.warnAmber : .white.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }

    private func dot(_ name: String, up: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(up ? Color.deltaGreen : Color.toolbarRed)
                .frame(width: 10, height: 10)
            Text(name)
                .font(.sofia(WidgetMetrics.minTextSize, .regular))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
