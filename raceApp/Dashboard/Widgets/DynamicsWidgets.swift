//
//  DynamicsWidgets.swift
//  raceApp
//
//  Friction-circle G meter with lateral / longitudinal / peak readouts.
//

import SwiftUI

struct GForceWidget: View {
    let context: WidgetContext

    var body: some View {
        let live = context.live
        switch context.size {
        case .large:
            VStack(alignment: .leading, spacing: 12) {
                meter.frame(maxWidth: .infinity, maxHeight: .infinity)
                readouts(live)
            }
        default:
            // Medium: three 48 pt readouts would starve the meter, so lat and
            // long stack in one column and peak waits for the large size.
            HStack(alignment: .bottom, spacing: 16) {
                meter.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    row("lat", live.latG)
                    row("long", live.longG)
                }
                .fixedSize()
            }
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            GMeterView(latG: context.live.latG, longG: context.live.longG,
                       peakG: context.live.peakG, trail: context.live.gTrail,
                       pointsPerG: side / 2 * 0.75)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func readouts(_ live: LiveSnapshot) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            column("lat", live.latG)
            column("long", live.longG)
            column(live.gCalibrated ? "peak" : "cal…", live.gCalibrated ? live.peakG : nil)
        }
    }

    private func row(_ name: String, _ g: Double?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            WidgetCaption(text: name).frame(width: 66, alignment: .leading)
            WidgetSecondaryValue(text: g.map { String(format: "%.2f", abs($0)) } ?? "—")
        }
    }

    private func column(_ name: String, _ g: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetCaption(text: name)
            WidgetSecondaryValue(text: g.map { String(format: "%.2f", abs($0)) } ?? "—")
        }
    }
}
