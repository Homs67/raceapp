//
//  LapWidgets.swift
//  raceApp
//
//  Lap Timer dashboard widgets (Figma 125:4704). Each switches on its size for
//  layout only — text sizes come from WidgetMetrics and never scale.
//

import SwiftUI
import SessionKit

struct LapTimeWidget: View {
    let context: WidgetContext

    var body: some View {
        let lap = context.live.lap
        switch context.size {
        case .large:
            // Recent laps stack above the hero: a 100 pt time already fills
            // the cell's width, so nothing fits beside it.
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lap.lapTimes.suffix(3).enumerated().reversed()), id: \.offset) { i, t in
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            WidgetCaption(text: "L\(lap.lapTimes.count - (lap.lapTimes.suffix(3).count - 1 - i))")
                                .frame(width: 44, alignment: .leading)
                            WidgetSecondaryValue(text: LapTimeFormat.string(t),
                                                 color: t == lap.bestLapTime ? Color.deltaGreen : .white.opacity(0.9))
                        }
                    }
                }
                WidgetValue(text: LapTimeFormat.string(lap.currentLapTime), context: context)
            }
        default:
            WidgetValue(text: LapTimeFormat.string(lap.currentLapTime), context: context)
        }
    }
}

struct LapDeltaWidget: View {
    let context: WidgetContext

    private var color: Color {
        guard let d = context.live.delta else { return .white.opacity(0.35) }
        return d < 0 ? Color.deltaGreen : Color.toolbarRed
    }

    var body: some View {
        let text = LapTimeFormat.delta(context.live.delta, coarse: context.live.coarseTiming)
        switch context.size {
        case .medium:
            VStack(alignment: .leading, spacing: 10) {
                WidgetValue(text: text, context: context, color: color)
                DeltaBar(delta: context.live.delta, color: color)
                    .frame(height: 6)
            }
        default:
            WidgetValue(text: text, context: context, color: color)
        }
    }
}

/// Signed bar, ±2 s full scale, centred on zero.
private struct DeltaBar: View {
    let delta: TimeInterval?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let clamped = max(-2, min(2, delta ?? 0))
            let width = abs(clamped) / 2 * half
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.widgetBorder).frame(height: 2).offset(y: 2)
                Rectangle().fill(Color.mutedWeak).frame(width: 1, height: 6).offset(x: half - 0.5)
                if delta != nil {
                    Rectangle().fill(color)
                        .frame(width: width, height: 6)
                        .offset(x: clamped < 0 ? half - width : half)
                }
            }
        }
    }
}

struct LapMapWidget: View {
    let context: WidgetContext

    var body: some View {
        let number = "\(context.live.lap.completedLaps + 1)"
        switch context.size {
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                map
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WidgetSecondaryValue(text: number)
            }
        default:
            HStack(alignment: .bottom, spacing: 12) {
                WidgetSecondaryValue(text: number)
                map
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var map: some View {
        if let track = context.track {
            TrackMapCanvas(track: track, position: context.live.position, style: .outline, padding: 4)
        } else {
            Color.clear
        }
    }
}

struct LastLapWidget: View {
    let context: WidgetContext

    var body: some View {
        let lap = context.live.lap
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 16) {
                WidgetValue(text: LapTimeFormat.string(lap.lastLapTime), context: context)
                if let last = lap.lastLapTime, let best = lap.bestLapTime {
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption(text: "vs best")
                        WidgetSecondaryValue(text: LapTimeFormat.delta(last - best),
                                             color: last - best <= 0 ? Color.deltaGreen : Color.toolbarRed)
                    }
                }
                Spacer(minLength: 0)
            }
        default:
            WidgetValue(text: LapTimeFormat.string(lap.lastLapTime), context: context)
        }
    }
}

struct BestLapWidget: View {
    let context: WidgetContext

    var body: some View {
        let lap = context.live.lap
        switch context.size {
        case .medium:
            HStack(alignment: .bottom, spacing: 16) {
                WidgetValue(text: LapTimeFormat.string(lap.bestLapTime), context: context)
                if let best = lap.bestLapTime, let index = lap.lapTimes.firstIndex(of: best) {
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetCaption(text: "lap")
                        WidgetSecondaryValue(text: "\(index + 1)")
                    }
                }
                Spacer(minLength: 0)
            }
        default:
            WidgetValue(text: LapTimeFormat.string(lap.bestLapTime), context: context)
        }
    }
}
