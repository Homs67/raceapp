//
//  StatusWidgets.swift
//  raceApp
//
//  Link health at a glance: OBD rate, GPS accuracy, RaceBox satellites.
//

import SwiftUI

struct StatusWidget: View {
    let context: WidgetContext

    var body: some View {
        let live = context.live
        VStack(alignment: .leading, spacing: 4) {
            line("OBD", live.obdHz > 0 ? String(format: "%.0f Hz", live.obdHz) : "—")
            line("GPS", live.gpsAccuracy.map { "±\(Int($0.rounded())) m" } ?? "—")
            line("RB", live.raceBox.map { "\($0.satellites) sats" } ?? "—")
        }
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetCaption(text: name).frame(width: 40, alignment: .leading)
            Text(value)
                .font(.sofiaNumeral(24, .bold))
                .kerning(WidgetMetrics.valueKerning)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

struct RaceBoxWidget: View {
    let context: WidgetContext

    var body: some View {
        let rb = context.live.raceBox
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 24) {
                column("sats", rb.map { "\($0.satellites)" } ?? "—")
                column("fix", rb.map { $0.has3DFix ? "3D" : "—" } ?? "—")
                column("power", rb?.powerText ?? "—")
                Spacer(minLength: 0)
            }
        default:
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                WidgetSecondaryValue(text: rb.map { "\($0.satellites)" } ?? "—")
                WidgetCaption(text: rb == nil ? "not linked" : (rb!.has3DFix ? "sats · 3D" : "sats · no fix"))
            }
        }
    }

    private func column(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetCaption(text: name)
            WidgetSecondaryValue(text: value)
        }
    }
}
