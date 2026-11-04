//
//  ContentView.swift
//  raceApp
//

import SwiftUI
import SessionKit

enum LaunchArgs {
    #if DEBUG
    static var openLatestSession: Bool {
        CommandLine.arguments.contains("-open-latest-session") || openLatestGraph || openLatestVideo
            || openSessionPrefix != nil
    }
    static var openLatestGraph: Bool { CommandLine.arguments.contains("-open-latest-graph") }
    /// `-open-session <uuid prefix>` opens that session's detail instead of the latest.
    static var openSessionPrefix: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "-open-session"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1].uppercased()
    }
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
            || CommandLine.arguments.contains("-emblem-playground")
    }
    static var debugRoute: String? {
        if CommandLine.arguments.contains("-tab-health") { return "health" }
        if CommandLine.arguments.contains("-tab-tracks") { return "tracks" }
        if CommandLine.arguments.contains("-open-diagnostics") { return "diagnostics" }
        if CommandLine.arguments.contains("-emblem-playground") { return "emblem" }
        return nil
    }
    #else
    static var openLatestSession: Bool { false }
    static var openLatestGraph: Bool { false }
    static var openSessionPrefix: String? { nil }
    static var openLatestVideo: Bool { false }
    static var openSettings: Bool { false }
    static var openDebug: Bool { false }
    static var debugRoute: String? { nil }
    #endif
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    /// car.side.fill is twice as wide as the other tab symbols, and the tab bar
    /// sizes every SF Symbol the same, so it's drawn into a template image at
    /// a smaller point size; the bar still tints it like the rest.
    static let profileTabIcon: UIImage = {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        guard let symbol = UIImage(systemName: "car.side.fill", withConfiguration: config) else { return UIImage() }
        return UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) }
            .withRenderingMode(.alwaysTemplate)
    }()

    var body: some View {
        TabView {
            SessionsView()
                .sessionPreviewBar(model)
                .tabItem { Label("Sessions", systemImage: "flag.checkered") }
            TracksView()
                .sessionPreviewBar(model)
                .tabItem { Label("Tracks", systemImage: "map") }
            ProfileView()
                .sessionPreviewBar(model)
                .tabItem { Label { Text("Profile") } icon: { Image(uiImage: Self.profileTabIcon) } }
        }
            .tint(Color.accent)
            // The dashboard is up while a session records *and* has not been
            // collapsed. Collapsing dismisses this cover and leaves the session
            // running behind the bar above the tab bar.
            .fullScreenCover(isPresented: Binding(
                get: { model.isDashboardPresented },
                set: { model.isDashboardPresented = $0 }
            )) {
                DashboardPagerView(mode: .recording)
                    .environment(model)
                    .interactiveDismissDisabled()
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
            // A drive just earned a track emblem: show it once the recording
            // dashboard has gone.
            .background {
                Color.clear.fullScreenCover(isPresented: Binding(
                    get: { model.achievements.pending != nil && !model.recording.isRecording },
                    set: { shown in
                        if !shown, let entry = model.achievements.pending { model.achievements.markAnnounced(entry) }
                    }
                )) {
                    if let entry = model.achievements.pending {
                        AchievementDetailView(entry: entry, isNew: true)
                            .environment(model)
                    }
                }
            }
            .task(id: model.recording.sessionsVersion) {
                model.achievements.refresh(model.store.list())
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
