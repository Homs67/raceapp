//
//  ContentView.swift
//  raceApp
//

import SwiftUI

enum LaunchArgs {
    #if DEBUG
    static var openLatestSession: Bool {
        CommandLine.arguments.contains("-open-latest-session") || openLatestGraph || openLatestVideo
    }
    static var openLatestGraph: Bool { CommandLine.arguments.contains("-open-latest-graph") }
    static var openLatestVideo: Bool { CommandLine.arguments.contains("-open-latest-video") }
    /// Opens Settings or Debug sheet after launch.
    static var openSettings: Bool {
        CommandLine.arguments.contains("-tab-settings")
            || CommandLine.arguments.contains("-tab-connection")
    }
    static var openDebug: Bool {
        CommandLine.arguments.contains("-tab-health")
            || CommandLine.arguments.contains("-tab-tracks")
            || CommandLine.arguments.contains("-tab-debug")
    }
    static var debugRoute: String? {
        if CommandLine.arguments.contains("-tab-health") { return "health" }
        if CommandLine.arguments.contains("-tab-tracks") { return "tracks" }
        if CommandLine.arguments.contains("-open-diagnostics") { return "diagnostics" }
        return nil
    }
    #else
    static var openLatestSession: Bool { false }
    static var openLatestGraph: Bool { false }
    static var openLatestVideo: Bool { false }
    static var openSettings: Bool { false }
    static var openDebug: Bool { false }
    static var debugRoute: String? { nil }
    #endif
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SessionsView()
            .tint(Color.accent)
            .fullScreenCover(isPresented: Binding(
                get: { model.dashboardExpanded && model.recording.isRecording },
                set: { if !$0 { model.dashboardExpanded = false } }
            )) {
                LiveDashboardView(onCollapse: { model.dashboardExpanded = false })
                    .environment(model)
            }
            .sheet(isPresented: Binding(
                get: { model.showSettings },
                set: {
                    model.showSettings = $0
                    if !$0 { model.connection.clearUIStatusOverride() }
                }
            )) {
                SettingsView()
                    .environment(model)
            }
            .sheet(isPresented: Binding(
                get: { model.showDebug },
                set: {
                    model.showDebug = $0
                    if !$0 { model.debugRoute = nil }
                }
            )) {
                DebugView()
                    .environment(model)
            }
            .onAppear {
                #if DEBUG
                if LaunchArgs.openSettings { model.showSettings = true }
                if LaunchArgs.openDebug {
                    model.debugRoute = LaunchArgs.debugRoute
                    model.showDebug = true
                }
                #endif
            }
    }
}
