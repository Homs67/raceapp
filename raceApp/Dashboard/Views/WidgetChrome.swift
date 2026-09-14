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
        if context.kind == .empty {
            Color.clear
        } else {
            chrome
        }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title ?? context.kind.title)
                .font(WidgetMetrics.titleFont)
                .kerning(WidgetMetrics.titleKerning)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Never less than 16 pt between the title and the content.
            Spacer(minLength: WidgetMetrics.titleContentGap)
            WidgetView(context: context)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .padding(context.contentInsets)
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
        case .predictedLap: PredictedLapWidget(context: context)
        case .sectorDelta: SectorDeltaWidget(context: context)
        case .lapCount: LapCountWidget(context: context)
        case .sessionTime: SessionTimeWidget(context: context)
        case .rpm: RpmWidget(context: context)
        case .speed: SpeedWidget(context: context)
        case .gear: GearWidget(context: context)
        case .shiftLights: ShiftLightsWidget(context: context)
        case .pedals: PedalsWidget(context: context)
        case .coolant: CoolantWidget(context: context)
        case .gForce: GForceWidget(context: context)
        case .trackMap: TrackMapWidget(context: context)
        case .altitude: AltitudeWidget(context: context)
        case .heading: HeadingWidget(context: context)
        case .status: StatusWidget(context: context)
        case .raceBox: RaceBoxWidget(context: context)
        case .camera: CameraWidget(context: context)
        case .unknown: WidgetValue(text: "—", context: context)
        case .empty: Color.clear
        }
    }
}
