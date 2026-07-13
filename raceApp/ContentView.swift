//
//  ContentView.swift
//  raceApp
//

import SwiftUI

enum LaunchArgs {
    #if DEBUG
    static var openLatestSession: Bool { CommandLine.arguments.contains("-open-latest-session") || openLatestGraph }
    static var openLatestGraph: Bool { CommandLine.arguments.contains("-open-latest-graph") }
    #else
    static var openLatestSession: Bool { false }
    static var openLatestGraph: Bool { false }
    #endif
    static var initialTab: Int {
        #if DEBUG
        if CommandLine.arguments.contains("-tab-health") { return 1 }
        if CommandLine.arguments.contains("-tab-connection") { return 3 }
        if CommandLine.arguments.contains("-tab-tracks") { return 4 }
        #endif
        return openLatestSession ? 2 : 0
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = LaunchArgs.initialTab

    var body: some View {
        TabView(selection: $selection) {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(0)
            HealthView()
                .tabItem { Label("Health", systemImage: "waveform.path.ecg") }
                .tag(1)
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
                .tag(2)
            TracksView()
                .tabItem { Label("Tracks", systemImage: "map") }
                .tag(4)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(Color.accent)
    }
}
