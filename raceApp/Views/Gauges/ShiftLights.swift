//
//  ShiftLights.swift
//  raceApp
//
//  Performance shift indicator: a sequential shift-light strip that fills as
//  RPM approaches the driver's chosen shift point and blinks at the point.
//  Palette-consistent escalation (dim → white → orange → red).
//

import SwiftUI

struct ShiftIndicator {
    var enabled: Bool
    var shiftRPM: Double
    /// RPM below the shift point where the lights begin to fill.
    var window: Double = 1500

    enum Phase: Equatable {
        case off              // disabled / no data
        case idle             // below the approach window
        case approach(Double) // 0…1 through the window
        case shift            // at or past the shift point
    }

    func phase(rpm: Double?) -> Phase {
        guard enabled, let rpm, shiftRPM > 0 else { return .off }
        if rpm >= shiftRPM { return .shift }
        let start = shiftRPM - window
        guard rpm >= start else { return .idle }
        return .approach(min(1, max(0, (rpm - start) / window)))
    }

    // ND2 MX-5 (7,500 redline) recommendations.
    static let redline: Double = 7500
    static let presets: [(name: String, rpm: Double, detail: String)] = [
        ("Economy", 3000, "Short-shift, save fuel"),
        ("Street", 5500, "Spirited but civil"),
        ("Track", 7200, "Max power, near redline"),
    ]
}

struct ShiftLightBar: View {
    var indicator: ShiftIndicator
    var rpm: Double?
    var segments: Int = 10
    var height: CGFloat = 8

    var body: some View {
        let phase = indicator.phase(rpm: rpm)
        TimelineView(.animation) { context in
            // Fast, smooth blink derived from absolute time (no jitter).
            let blink = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 0.3)
            HStack(spacing: 4) {
                ForEach(0..<segments, id: \.self) { index in
                    Capsule()
                        .fill(color(for: index, phase: phase, blink: blink))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
            .opacity(phase == .off ? 0 : 1)
            .animation(.easeOut(duration: 0.08), value: litCount(phase))
        }
        .frame(height: height)
    }

    private func litCount(_ phase: ShiftIndicator.Phase) -> Int {
        switch phase {
        case .off, .idle: return 0
        case .approach(let progress): return Int((progress * Double(segments)).rounded())
        case .shift: return segments
        }
    }

    private func color(for index: Int, phase: ShiftIndicator.Phase, blink: Double) -> Color {
        let dim = Color.white.opacity(0.08)
        switch phase {
        case .off, .idle:
            return dim
        case .approach:
            return index < litCount(phase) ? rampColor(index) : dim
        case .shift:
            return Color.recordRed.opacity(0.25 + 0.75 * blink)
        }
    }

    /// Left segments white, middle orange, right red.
    private func rampColor(_ index: Int) -> Color {
        let t = Double(index) / Double(max(1, segments - 1))
        if t < 0.5 { return .white }
        if t < 0.8 { return .accent }
        return .recordRed
    }
}
