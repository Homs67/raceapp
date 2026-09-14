//
//  EngineWidgets.swift
//  raceApp
//
//  RPM, speed, gear, shift lights, pedals, coolant. Values are stale-honest:
//  nil renders "—", never a frozen number.
//

import SwiftUI

private func whole(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "—" }

struct RpmWidget: View {
    let context: WidgetContext

    var body: some View {
        WidgetValue(text: whole(context.live.rpm), context: context)
    }
}

struct SpeedWidget: View {
    let context: WidgetContext

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            WidgetValue(text: whole(context.live.speedDisplay), context: context)
            WidgetCaption(text: context.units.speedUnit)
        }
    }
}

/// Strict 48 pt in every size — a gear is one glyph, a bigger cell is not a
/// bigger number.
struct GearWidget: View {
    let context: WidgetContext

    var body: some View {
        let gear = context.live.gear
        WidgetSecondaryValue(text: gear.map { $0 == 0 ? "N" : "\($0)" } ?? "—")
    }
}

/// Plain RPM above the sequential strip; approach/blink follow the shift
/// preset from Settings. Disabled preset → the strip stays dark.
struct ShiftLightsWidget: View {
    let context: WidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                WidgetSecondaryValue(text: whole(context.live.rpm))
                WidgetCaption(text: context.live.shift.enabled
                              ? "shift \(Int(context.live.shift.shiftRPM))" : "shift off")
            }
            ShiftLightBar(indicator: context.live.shift, rpm: context.live.rpm, height: 14)
                .opacity(context.live.shift.enabled ? 1 : 0.3)
        }
    }
}

/// Accelerator and brake as two bars; the numbers only at medium.
struct PedalsWidget: View {
    let context: WidgetContext

    var body: some View {
        let accel = context.live.accelPedal
        let brake = context.live.brake
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 24) {
                pedal("throttle", accel, Color.deltaGreen)
                pedal("brake", brake, Color.toolbarRed)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                PedalBar(percent: accel, color: Color.deltaGreen)
                PedalBar(percent: brake, color: Color.toolbarRed)
            }
        }
    }

    private func pedal(_ name: String, _ value: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                WidgetSecondaryValue(text: whole(value))
                WidgetCaption(text: name)
            }
            PedalBar(percent: value, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PedalBar: View {
    let percent: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * min(1, max(0, (percent ?? 0) / 100))))
            }
        }
        .frame(height: 10)
    }
}

struct CoolantWidget: View {
    let context: WidgetContext

    var body: some View {
        let c = context.live.coolantC
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetSecondaryValue(text: c.map { whole(context.units.temp(fromC: $0)) } ?? "—",
                                 color: (c ?? 0) >= 110 ? Color.toolbarRed : .white.opacity(0.9))
            WidgetCaption(text: context.units.tempUnit)
        }
    }
}
