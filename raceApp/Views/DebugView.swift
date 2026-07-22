//
//  DebugView.swift
//  raceApp
//
//  Testing tools + track library (wireframe). Presented as a sheet from Sessions.
//

import SwiftUI

struct DebugView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ScreenPageTitle(title: "Debug")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                Section("Testing") {
                    Toggle("Demo data", isOn: Binding(
                        get: { model.connection.isDemo },
                        set: { on in
                            if on {
                                model.connection.startDemo()
                            } else {
                                model.connection.stopDemo()
                            }
                        }
                    ))
                    .font(.system(size: 15))
                    .listRowBackground(Color.cardGray)

                    NavigationLink("Vehicle health data", value: "health")
                        .font(.system(size: 15))
                        .listRowBackground(Color.cardGray)

                    NavigationLink("OBD-II diagnostics", value: "diagnostics")
                        .font(.system(size: 15))
                        .listRowBackground(Color.cardGray)
                }

                Section {
                    Button("Walk through OBD statuses") {
                        presentSettingsPreview {
                            model.connection.playAdapterStatusWalkthrough()
                        }
                    }
                    .font(.system(size: 15))
                    .listRowBackground(Color.cardGray)

                    ForEach(OBDAdapterUIStatus.previewCatalog) { step in
                        Button(step.previewLabel) {
                            presentSettingsPreview {
                                model.connection.uiStatusOverride = step
                            }
                        }
                        .font(.system(size: 15))
                        .listRowBackground(Color.cardGray)
                    }

                    if model.connection.uiStatusOverride != nil {
                        Button("Clear OBD status preview", role: .destructive) {
                            model.connection.clearUIStatusOverride()
                        }
                        .font(.system(size: 15))
                        .listRowBackground(Color.cardGray)
                    }
                } header: {
                    Text("OBD status preview")
                } footer: {
                    Text("Forces the Settings OBD card through each step without Bluetooth hardware. Demo data still runs a real simulated connect.")
                }

                Section("Track library") {
                    ForEach(TrackDatabase.all) { track in
                        NavigationLink(value: "track:\(track.id)") {
                            Text(track.name)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.textPrimary)
                        }
                        .listRowBackground(Color.cardGray)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bgScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: String.self) { route in
                switch route {
                case "health":
                    HealthView()
                        .navigationTitle("Vehicle health data")
                        .navigationBarTitleDisplayMode(.inline)
                case "diagnostics":
                    DiagnosticsView()
                case let trackRoute where trackRoute.hasPrefix("track:"):
                    let id = String(trackRoute.dropFirst("track:".count))
                    if let track = TrackDatabase.track(id: id) {
                        TrackDetailView(track: track)
                    } else {
                        ContentUnavailableView("Track not found", systemImage: "map")
                    }
                default:
                    EmptyView()
                }
            }
            .onAppear {
                if let route = model.debugRoute {
                    path = [route]
                    model.debugRoute = nil
                }
            }
        }
    }

    /// Dismiss Debug first so the Settings sheet can present cleanly.
    private func presentSettingsPreview(_ prepare: @escaping () -> Void) {
        model.showDebug = false
        prepare()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            model.showSettings = true
        }
    }
}
