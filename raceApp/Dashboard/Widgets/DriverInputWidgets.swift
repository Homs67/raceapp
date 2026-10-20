//
//  DriverInputWidgets.swift
//  raceApp
//
//  Steering angle and acceleration runs.
//

import SwiftUI
import SessionKit

/// Front wheel angle, + to the right.
///
/// The CAN bus reports the *steering wheel*, which swings about ±480° and is
/// hard to read at a glance. Dividing by the steering ratio gives the angle
/// the road wheels are actually turned to — a much smaller number that means
/// something physical. The recorded `can.steering` channel keeps the raw
/// wheel angle; only the display converts.
struct SteeringWidget: View {
    let context: WidgetContext

    /// ND MX-5: roughly 2.7 turns lock to lock (~±486° at the wheel) through
    /// a ~15:1 rack, which puts full lock near ±32° at the road wheels.
    /// Worth confirming against your own car — it only scales the reading.
    static let steeringRatio: Double = 15.0
    /// End stops for the gauge. The number itself is never clamped.
    static let maxWheelAngle: Double = 33

    private var wheelAngle: Double? {
        context.live.steering.map { $0 / Self.steeringRatio }
    }

    var body: some View {
        Group {
            switch context.size {
            case .medium:
                HStack(alignment: .bottom, spacing: 18) {
                    SteeringArc(angle: wheelAngle, maxAngle: Self.maxWheelAngle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption(text: side(wheelAngle))
                        WidgetValue(text: text(wheelAngle), context: context)
                    }
                    .fixedSize()
                }
            default:
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    WidgetValue(text: text(wheelAngle), context: context)
                    WidgetCaption(text: side(wheelAngle))
                }
            }
        }
        .heldValue(context.live.canStale)
    }

    private func text(_ angle: Double?) -> String {
        guard let angle else { return "—" }
        return String(Int(angle.rounded())) + "°"
    }

    private func side(_ angle: Double?) -> String {
        guard let angle, abs(angle) >= 1 else { return "centred" }
        return angle > 0 ? "right" : "left"
    }
}

/// Arc gauge with zero straight up: the needle leans the way the wheels are
/// pointed, which reads the same way the car feels.
private struct SteeringArc: View {
    let angle: Double?
    let maxAngle: Double

    /// Half the visual sweep. Full lock lands here, well short of the
    /// horizontal, so the arc still reads as "ahead".
    private static let halfSweep: Double = 70

    var body: some View {
        Canvas { ctx, size in
            // Pivot low so the arc uses the cell's width, like a rev counter.
            let radius = min(size.width / 2, size.height) * 0.92
            let centre = CGPoint(x: size.width / 2, y: size.height)
            let up = -90.0

            var track = Path()
            track.addArc(center: centre, radius: radius,
                         startAngle: .degrees(up - Self.halfSweep),
                         endAngle: .degrees(up + Self.halfSweep),
                         clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.10)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))

            // Centre tick: the reference the eye returns to.
            let tickOuter = point(centre, radius + 5, up)
            let tickInner = point(centre, radius - 9, up)
            var tick = Path()
            tick.move(to: tickInner)
            tick.addLine(to: tickOuter)
            ctx.stroke(tick, with: .color(.white.opacity(0.45)), lineWidth: 2)

            guard let angle else { return }
            let fraction = max(-1, min(1, angle / maxAngle))
            let target = up + fraction * Self.halfSweep

            var fill = Path()
            fill.addArc(center: centre, radius: radius,
                        startAngle: .degrees(min(up, target)),
                        endAngle: .degrees(max(up, target)),
                        clockwise: false)
            ctx.stroke(fill, with: .color(.accent),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))

            let knob = point(centre, radius, target)
            ctx.fill(Path(ellipseIn: CGRect(x: knob.x - 6, y: knob.y - 6, width: 12, height: 12)),
                     with: .color(.accent))
        }
        .aspectRatio(2, contentMode: .fit)
    }

    private func point(_ centre: CGPoint, _ radius: Double, _ degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: centre.x + cos(r) * radius, y: centre.y + sin(r) * radius)
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
