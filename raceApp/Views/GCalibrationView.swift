//
//  GCalibrationView.swift
//  raceApp
//
//  Guided car-frame calibration for a connected RaceBox, as a half-height
//  sheet showing one step at a time.
//
//  Calibration is passive — ordinary driving satisfies the same conditions
//  within a minute or two — so this is a deliberate pre-session ritual, not
//  a gate. Its value is telling you *which* requirement is still missing
//  instead of leaving a blank gauge and no explanation.
//
//  Nothing advances on sensor state alone: each step waits for the driver to
//  say they are ready, because "the car happens to be still" and "the driver
//  is parked and paying attention" are different things.
//

import SwiftUI
import SessionKit

struct GCalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false

    private enum Step { case level, align, done }

    @State private var step: Step = .level
    @State private var holdRemaining: Int?
    @State private var holdTask: Task<Void, Never>?
    @State private var measuring = false
    @State private var levelFailed = false

    /// The fit ignores anything slower than 3 m/s.
    private var minimumSpeedText: String { metric ? "11 km/h" : "7 mph" }
    private var targetSpeedText: String { metric ? "50 km/h" : "30 mph" }

    var body: some View {
        NavigationStack {
            Group {
                if model.raceBox.state == .connected {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        current
                    }
                } else {
                    notConnected
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.bgScreen)
            .navigationTitle("Calibrate G-Force")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .done ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(Color.accent)
        .preferredColorScheme(.dark)
        .onAppear(perform: resume)
        .onDisappear { holdTask?.cancel() }
    }

    /// Opening on a device that is already properly calibrated should show
    /// the result rather than ask for a drive that already happened. A frame
    /// that solved but scores outside the trusted band is not good enough to
    /// skip the drive for — that is exactly the "plausible but wrong" case.
    private func resume() {
        if model.raceBox.framePhase == .calibrated,
           model.raceBox.frameQuality?.isTrustworthy == true {
            step = .done
        }
    }

    @ViewBuilder
    private var current: some View {
        switch step {
        case .level: levelStep
        case .align: alignStep
        case .done: doneStep
        }
    }

    // MARK: - Step 1 · level

    @ViewBuilder
    private var levelStep: some View {
        stepBody(
            number: 1, of: 2,
            title: "Park and hold still",
            detail: "Finds which way is down, and zeroes the gyro. Engine running is fine — just don't move the car."
        ) {
            if let remaining = holdRemaining {
                countdown(remaining)
            } else {
                if levelFailed {
                    note("The car moved. Come to a complete stop and try again.", warning: true)
                }
                primaryButton("I'm parked") { beginHold() }
            }
        }
    }

    private func beginHold() {
        levelFailed = false
        holdTask?.cancel()
        holdRemaining = 3
        holdTask = Task {
            for value in stride(from: 3, through: 1, by: -1) {
                holdRemaining = value
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            holdRemaining = nil
            // Levelling only accumulates while the device is genuinely still,
            // so the phase is the honest answer to "did that work".
            if model.raceBox.framePhase == .leveling {
                levelFailed = true
            } else {
                withAnimation(.snappy(duration: 0.25)) { step = .align }
            }
        }
    }

    // MARK: - Step 2 · align

    private var quality: CarFrameCalibrator.FitQuality? { model.raceBox.frameQuality }
    private var windows: Int { quality?.windowCount ?? 0 }
    /// 20 windows is what `FitQuality.isTrustworthy` wants.
    private let windowTarget = 20
    private var spreadOK: Bool { (quality?.accelSpread ?? 0) >= 0.05 }

    @ViewBuilder
    private var alignStep: some View {
        stepBody(
            number: 2, of: 2,
            title: "Three straight-line pulls",
            detail: "Finds which way is forward by matching the accelerometer against GPS speed. On a clear, straight road: accelerate briskly to about \(targetSpeedText), then brake firmly down to walking pace. Repeat three times."
        ) {
            if measuring {
                VStack(alignment: .leading, spacing: 12) {
                    progress
                    requirement("Above \(minimumSpeedText)", met: windows > 0,
                                hint: "Below this, GPS speed can't tell forward from backward")
                    requirement("Hard enough acceleration and braking", met: spreadOK,
                                hint: "Needs a real difference between the gentlest and firmest")
                }
                .onChange(of: windows) {
                    if model.raceBox.framePhase == .calibrated, windows >= windowTarget {
                        withAnimation(.snappy(duration: 0.25)) { step = .done }
                    }
                }
            } else {
                primaryButton("Start drive") { measuring = true }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(min(windows, windowTarget)) / \(windowTarget) good seconds")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            ProgressView(value: Double(min(windows, windowTarget)), total: Double(windowTarget))
                .tint(Color.accent)
        }
    }

    // MARK: - Step 3 · result

    @ViewBuilder
    private var doneStep: some View {
        let good = quality?.isTrustworthy == true
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(good ? Color.deltaGreen : Color.warnAmber)
                Text(good ? "Calibrated" : "Low confidence")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
            }
            if let q = quality {
                // Scale is the number that exposes a plausible-but-wrong fit:
                // 1.00 is perfect, and the validator accepts 0.80–1.25. A fit
                // can correlate beautifully and still point the wrong way.
                Text("Confidence \(String(format: "%.2f", q.scale))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(good
                     ? "Saved for this RaceBox — later drives start already aligned. It keeps refining as you drive."
                     : "The forward axis may be off. Drive a little more with firmer acceleration and braking, or start over.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Start calibration over") {
                holdTask?.cancel()
                holdRemaining = nil
                measuring = false
                levelFailed = false
                model.raceBox.forgetFrameCalibration()
                withAnimation(.snappy(duration: 0.25)) { step = .level }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.recordRed)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    @ViewBuilder
    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No RaceBox connected")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("This calibrates the logger's own accelerometer, which is bolted to the car. Connect a RaceBox first.")
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
        }
        .padding(24)
    }

    // MARK: - Pieces

    private func stepBody<Content: View>(number: Int, of total: Int, title: String,
                                         detail: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STEP \(number) OF \(total)")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Color.accent)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func countdown(_ value: Int) -> some View {
        HStack(spacing: 14) {
            ProgressView()
            Text("Levelling… \(value)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
    }

    private func note(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(warning ? Color.warnAmber : Color.muted)
            Text(text).font(.system(size: 13)).foregroundStyle(Color.muted)
        }
        .padding(.bottom, 4)
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
