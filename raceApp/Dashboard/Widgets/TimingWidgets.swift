//
//  TimingWidgets.swift
//  raceApp
//
//  Predicted lap, sector deltas, lap count and session time.
//

import SwiftUI
import SessionKit

/// Best lap + live delta. Hero at medium; "—:—" until there is a best lap.
struct PredictedLapWidget: View {
    let context: WidgetContext

    var body: some View {
        // A 100 pt "0:00.00" fills a medium cell; nothing else fits beside it.
        WidgetValue(text: LapTimeFormat.string(context.live.predictedLap), context: context)
    }
}

/// Three equal-distance sectors; completed ones hold their delta, the current
/// one runs live and is drawn brighter.
struct SectorDeltaWidget: View {
    let context: WidgetContext

    var body: some View {
        let live = context.live
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                let isCurrent = i == live.currentSector
                let value: TimeInterval? = isCurrent ? live.currentSectorDelta : live.sectorDeltas[i]
                VStack(alignment: .leading, spacing: 2) {
                    WidgetCaption(text: "S\(i + 1)")
                    // Tenths: three signed 48 pt values share one medium row.
                    WidgetSecondaryValue(text: LapTimeFormat.delta(value, coarse: true),
                                         color: deltaColor(value, dimmed: !isCurrent && i > live.currentSector))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func deltaColor(_ value: TimeInterval?, dimmed: Bool) -> Color {
        guard let value else { return .white.opacity(dimmed ? 0.2 : 0.35) }
        return value <= 0 ? Color.deltaGreen : Color.toolbarRed
    }
}

/// Plain lap number — the map lives in `lapMap`.
struct LapCountWidget: View {
    let context: WidgetContext

    var body: some View {
        let lap = context.live.lap
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 16) {
                WidgetValue(text: "\(lap.completedLaps + 1)", context: context)
                VStack(alignment: .leading, spacing: 2) {
                    WidgetCaption(text: "completed")
                    WidgetSecondaryValue(text: "\(lap.completedLaps)", color: .white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
        default:
            WidgetValue(text: "\(lap.completedLaps + 1)", context: context)
        }
    }
}

/// Elapsed session time, now that the toolbar hides it by default.
struct SessionTimeWidget: View {
    let context: WidgetContext

    var body: some View {
        let text = SessionElapsedFormat.formatLong(context.live.elapsed)
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 16) {
                WidgetValue(text: text, context: context)
                VStack(alignment: .leading, spacing: 2) {
                    WidgetCaption(text: "laps")
                    WidgetSecondaryValue(text: "\(context.live.lap.completedLaps)", color: .white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
        default:
            WidgetValue(text: text, context: context)
        }
    }
}
