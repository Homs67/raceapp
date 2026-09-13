//
//  WidgetChrome.swift
//  raceApp
//
//  The frame every widget lives in: 16 pt padding, uppercase title top-left,
//  content pinned to the bottom. Draws no border — the grid canvas strokes all
//  cell edges once so zero-spacing neighbours never double up.
//

import SwiftUI

struct WidgetChrome: View {
    let context: WidgetContext
    /// Title override (LapMapWidget titles itself "LAP").
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title ?? context.kind.title)
                .font(WidgetMetrics.titleFont)
                .kerning(WidgetMetrics.titleKerning)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            WidgetView(context: context)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .padding(WidgetMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
    }
}

/// Exhaustive dispatcher — adding a kind without a view is a compile error.
struct WidgetView: View {
    let context: WidgetContext

    var body: some View {
        switch context.kind {
        case .lapTime: LapTimeWidget(context: context)
        case .lapDelta: LapDeltaWidget(context: context)
        case .lapMap: LapMapWidget(context: context)
        case .lastLap: LastLapWidget(context: context)
        case .bestLap: BestLapWidget(context: context)
        case .unknown: WidgetValue(text: "—", context: context)
        }
    }
}
