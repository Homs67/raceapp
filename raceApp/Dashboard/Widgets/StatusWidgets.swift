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
            WidgetCaption(text: name).frame(width: 56, alignment: .leading)
            Text(value)
                .font(.sofiaNumeral(24, .bold))
                .kerning(WidgetMetrics.valueKerning)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

