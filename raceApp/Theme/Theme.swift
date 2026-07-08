//
//  Theme.swift
//  raceApp
//
//  Design tokens per 09-design-notes.md / design handoff README.
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let bgScreen = Color(hex: 0x0B0C0F)
    static let bgSheet = Color(hex: 0x1A1C21)
    static let textPrimary = Color(hex: 0xF2F5F7)
    static let accentCyan = Color(hex: 0x64D2FF)
    static let okGreen = Color(hex: 0x32D74B)
    static let recordRed = Color(hex: 0xFF453A)
    static let warnAmber = Color(hex: 0xFFD60A)

    static let mutedStrong = Color.white.opacity(0.55)
    static let muted = Color.white.opacity(0.4)
    static let mutedWeak = Color.white.opacity(0.3)
    static let cardBg = Color.white.opacity(0.045)
    static let cardBorder = Color.white.opacity(0.08)
}

extension Font {
    /// Giant condensed numerals (design: Saira Condensed; native substitute
    /// per 09-design-notes: condensed SF with tabular digits).
    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.compressed).monospacedDigit()
    }

    /// 9–11pt uppercase micro-labels.
    static func microLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium)
    }
}

/// Status chip (ADAPTER / CAR / OBD Hz / GPS ±m / REC).
struct StatusChip: View {
    var text: String
    var dotColor: Color?
    var tint: Color = .mutedStrong
    var background: Color = .white.opacity(0.06)
    var pulsing = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .opacity(pulsing ? (pulse ? 1 : 0.25) : 1)
                    .animation(pulsing ? .easeInOut(duration: 0.6).repeatForever() : nil, value: pulse)
            }
            Text(text)
                .font(.microLabel())
                .kerning(1)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .onAppear { if pulsing { pulse = true } }
    }
}

/// Formatting per the global units setting (imperial default, R5.3).
struct UnitsFormatter {
    var metric: Bool

    var speedUnit: String { metric ? "KM/H" : "MPH" }
    func speed(fromKmh kmh: Double) -> Double { metric ? kmh : kmh * 0.621371 }
    func speed(fromMps mps: Double) -> Double { speed(fromKmh: mps * 3.6) }

    var tempUnit: String { metric ? "°C" : "°F" }
    func temp(fromC c: Double) -> Double { metric ? c : c * 9 / 5 + 32 }

    var shortDistanceUnit: String { metric ? "m" : "ft" }
    func shortDistance(fromMeters m: Double) -> Double { metric ? m : m * 3.28084 }

    var distanceUnit: String { metric ? "km" : "mi" }
    func distance(fromMeters m: Double) -> Double { metric ? m / 1000 : m / 1609.344 }
}
