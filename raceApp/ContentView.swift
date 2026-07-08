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
    static var initialTab: Int { openLatestSession ? 2 : 0 }
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
            ConnectionView()
                .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(3)
        }
        .tint(Color.accent)
    }
}
