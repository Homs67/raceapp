//
//  SessionControls.swift
//  raceApp
//
//  Session start/stop controls and time formatters shared by the Sessions
//  surface, the mini-player, and the recording dashboard.
//

import SwiftUI

/// Large orange circular Start used on the Sessions idle surface.
struct SessionStartButton: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useMetricUnits") private var metric = false
    var size: CGFloat = 96

    var body: some View {
        Button {
            model.startRecording(metricUnits: metric)
        } label: {
            Text("START")
                .font(.numeral(size * 0.32, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Color.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Start")
    }
}

/// Circular red Stop used on the mini-player (the dashboard toolbar has its own).
struct SessionStopButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 64

    var body: some View {
        Button {
            model.stopRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.recordRed)
                    .frame(width: size, height: size)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.black)
                    .frame(width: size * 0.28, height: size * 0.28)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Stop Recording")
    }
}

enum SessionElapsedFormat {
    static func format(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Toolbar / banner style: always `HH:MM:SS`.
    static func formatLong(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

enum LapTimeFormat {
    /// `m:ss.hh`; `—:—` when there is no lap yet.
    static func string(_ t: TimeInterval?) -> String {
        guard let t else { return "—:—" }
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    /// Signed delta: `−0.34` / `+1.07`, `m:ss.h` once a minute or more. Tenths
    /// only when `coarse` (phone GPS worse than ~5 m) so the last digit is honest.
    static func delta(_ d: TimeInterval?, coarse: Bool = false) -> String {
        guard let d else { return "—" }
        let sign = d < 0 ? "−" : "+"
        let a = abs(d)
        if a >= 60 {
            let m = Int(a) / 60, s = a - Double(m * 60)
            return String(format: "%@%d:%04.1f", sign, m, s)
        }
        return String(format: coarse ? "%@%.1f" : "%@%.2f", sign, a)
    }
}

/// Subtle press feedback for the big buttons.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

func uptimeNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
