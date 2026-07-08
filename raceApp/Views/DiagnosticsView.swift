//
//  DiagnosticsView.swift
//  raceApp
//
//  Runs the OBD-II diagnostic sweep (03 §6) and produces a shareable report:
//  supported channels + live values, multi-PID support, effective data rate,
//  protocol, and the adapter's Bluetooth/GATT details. This is how a real car's
//  capabilities get captured and sent back for car-specific tuning.
//

import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var report: DiagnosticsReport?
    @State private var reportFile: URL?
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect the adapter with the ignition on (engine running is best), then run the sweep. It asks the ECU exactly what it supports, reads a live value from each sensor, measures the real data rate, and records the adapter's Bluetooth details. Share the report so the app can be tuned to this specific car.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)

                Button {
                    run()
                } label: {
                    HStack(spacing: 8) {
                        if running { ProgressView().tint(.white) }
                        Text(running ? "Running sweep…" : "Run diagnostics")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(model.connection.canRunDiagnostics ? Color.accent : Color.cardGray,
                               in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(running || !model.connection.canRunDiagnostics)

                if !model.connection.canRunDiagnostics {
                    Text("Not connected. Connect the adapter (or start demo) in the Connection tab first.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recordRed)
                }

                if let report {
                    Text(report.readableText())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 12))

                    if let reportFile {
                        ShareLink(item: reportFile) {
                            Label("Share report (JSON)", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accent.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.bgScreen)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        running = true
        Task {
            let result = await model.connection.runDiagnostics()
            report = result
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("raceapp-diagnostics.json")
            try? result.jsonData().write(to: url, options: .atomic)
            reportFile = url
            running = false
        }
    }
}
