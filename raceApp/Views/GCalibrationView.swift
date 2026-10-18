//
//  GCalibrationView.swift
//  raceApp
//
//  Guided car-frame calibration for a connected RaceBox.
//
//  Calibration is passive — ordinary driving satisfies the same conditions
//  within a minute or two — so this is a deliberate pre-session ritual, not
//  a gate. Its value is telling you *which* requirement is still missing
//  instead of leaving a blank gauge and no explanation.
//

import SwiftUI
import SessionKit

struct GCalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false

    /// Levelling needs ~1.5 s of stillness; count down a little longer so the
    /// car has settled before it starts accumulating.
    @State private var holdRemaining: Int?
    @State private var holdTask: Task<Void, Never>?
    @State private var driving = false

    private var units: UnitsFormatter { UnitsFormatter(metric: metric) }
    /// The fit ignores anything slower than 3 m/s.
    private var minimumSpeedText: String {
        metric ? "11 km/h" : "7 mph"
    }
    private var targetSpeedText: String {
        metric ? "50 km/h" : "30 mph"
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                List {
                    if model.raceBox.state == .connected {
                        stepOne
                        stepTwo
                        if case .calibrated = model.raceBox.framePhase { stepThree }
                        resetSection
                    } else {
                        Section {
                            Text("Connect a RaceBox first — this calibrates the logger's own accelerometer, which is bolted to the car.")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.muted)
                        }
                        .listRowBackground(Color.cardBg)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.bgScreen)
            }
            .navigationTitle("Calibrate G-Force")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Color.accent)
        .preferredColorScheme(.dark)
        .onDisappear { holdTask?.cancel() }
    }

    // MARK: - Step 1 · level

    private var levelled: Bool { model.raceBox.framePhase != .leveling }

    @ViewBuilder
    private var stepOne: some View {
        Section {
            stepHeader(1, "Park and hold still", done: levelled)
            Text("Finds which way is down, and zeroes the gyro. Engine running is fine — just don't move the car.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)

            if levelled {
                statusLine("Level", detail: "Down and gyro zero found", ok: true)
            } else if let remaining = holdRemaining {
                statusLine("Levelling…", detail: "\(remaining)", ok: false)
            } else {
                Button("I'm parked") { beginHold() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accent)
            }
        }
        .listRowBackground(Color.cardBg)
    }

    private func beginHold() {
        holdTask?.cancel()
        holdRemaining = 3
        holdTask = Task {
            for value in stride(from: 3, through: 1, by: -1) {
                holdRemaining = value
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            holdRemaining = nil
        }
    }

    // MARK: - Step 2 · align

    private var quality: CarFrameCalibrator.FitQuality? { model.raceBox.frameQuality }
    private var windows: Int { quality?.windowCount ?? 0 }
    /// 20 windows is what `FitQuality.isTrustworthy` wants.
    private var windowTarget: Int { 20 }
    private var spreadOK: Bool { (quality?.accelSpread ?? 0) >= 0.05 }
    private var aligned: Bool { model.raceBox.framePhase == .calibrated }

    @ViewBuilder
    private var stepTwo: some View {
        Section {
            stepHeader(2, "Three straight-line pulls", done: aligned && windows >= windowTarget)
            Text("Finds which way is forward by matching the accelerometer against GPS speed. On a clear, straight road: accelerate briskly to about \(targetSpeedText), then brake firmly down to walking pace. Repeat three times.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)

            if !driving && !aligned {
                Button("Start drive") { driving = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .disabled(!levelled)
            } else {
                progressRow
                requirement("Above \(minimumSpeedText)", met: windows > 0,
                            hint: "Slower than this, GPS speed can't tell forward from backward")
                requirement("Hard enough acceleration and braking", met: spreadOK,
                            hint: "Needs a real difference between the gentlest and firmest")
            }
        }
        .listRowBackground(Color.cardBg)
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(min(windows, windowTarget)) / \(windowTarget) good seconds")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if aligned {
                    Text("aligned").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.deltaGreen)
                }
            }
            ProgressView(value: Double(min(windows, windowTarget)), total: Double(windowTarget))
                .tint(aligned ? Color.deltaGreen : Color.accent)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Step 3 · confirm

    @ViewBuilder
    private var stepThree: some View {
        Section {
            stepHeader(3, "Done", done: true)
            if let q = quality {
                // Scale is the number that exposes a plausible-but-wrong fit:
                // 1.00 is perfect, and the validator accepts 0.80–1.25.
                statusLine("Confidence \(String(format: "%.2f", q.scale))",
                           detail: q.isTrustworthy
                               ? "Saved for this RaceBox — later drives start aligned"
                               : "Usable, still improving as you drive",
                           ok: q.isTrustworthy)
            }
            Text("Keeps refining while you drive. You only need to repeat this if the RaceBox moves to another car.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)
        }
        .listRowBackground(Color.cardBg)
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("Start calibration over") {
                holdTask?.cancel()
                holdRemaining = nil
                driving = false
                model.raceBox.forgetFrameCalibration()
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.recordRed)
        } footer: {
            if model.raceBox.hasStoredFrame {
                Text("A saved alignment for this device is in use.")
            }
        }
        .listRowBackground(Color.cardBg)
    }

    // MARK: - Pieces

    private func stepHeader(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.deltaGreen : Color.cardGray).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.textPrimary)
                }
            }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.textPrimary)
        }
    }

    private func statusLine(_ title: String, detail: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(ok ? Color.deltaGreen : Color.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted)
            }
        }
    }

    private func requirement(_ title: String, met: Bool, hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? Color.deltaGreen : Color.mutedWeak)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Color.textPrimary)
                if !met {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Color.muted)
                }
            }
        }
    }
}
