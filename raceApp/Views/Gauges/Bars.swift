//
//  Bars.swift
//  raceApp
//
//  Tach bar (with red zone) and throttle bar per design.
//

import SwiftUI

struct TachBar: View {
    var rpm: Double? // nil = stale
    var redline: Double = 7500
    var redZoneWidth: Double = 700
    var height: CGFloat = 20
    var segmented = false

    var nearRedline: Bool { (rpm ?? 0) >= redline - redZoneWidth }

    var body: some View {
        GeometryReader { geo in
            let fillFraction = min(1, max(0, (rpm ?? 0) / redline))
            let redStart = (redline - redZoneWidth) / redline
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07))
                // Red zone overlay
                Rectangle()
                    .fill(Color.recordRed.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.recordRed.opacity(0.7)).frame(width: 2)
                    }
                    .frame(width: geo.size.width * (1 - redStart))
                    .offset(x: geo.size.width * redStart)
                // Fill
                RoundedRectangle(cornerRadius: 5)
                    .fill(nearRedline ? Color.recordRed : Color.textPrimary)
                    .frame(width: max(0, geo.size.width * fillFraction))
                    .animation(.linear(duration: 0.07), value: fillFraction)
                // Segment separators (landscape variant)
                if segmented {
                    HStack(spacing: 0) {
                        ForEach(1..<15, id: \.self) { _ in
                            Spacer()
                            Rectangle().fill(Color.black).frame(width: 2)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: height)
    }
}

struct ThrottleBar: View {
    var percent: Double? // nil = stale
    var barWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text("THR")
                .font(.microLabel(9)).kerning(1.2)
                .foregroundStyle(Color.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Color.accent)
                        .frame(width: max(0, geo.size.width * (percent ?? 0) / 100))
                        .animation(.linear(duration: 0.07), value: percent ?? 0)
                }
            }
            .frame(width: barWidth, height: 9)
            Text(percent.map { "\(Int($0))%" } ?? "—")
                .font(.system(size: 14, weight: .medium)).monospacedDigit()
                .foregroundStyle(percent == nil ? Color.mutedWeak : Color.accent)
                .frame(minWidth: 42, alignment: .trailing)
        }
    }
}
