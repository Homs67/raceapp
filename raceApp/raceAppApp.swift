 //
//  raceAppApp.swift
//  raceApp
//

import SwiftUI

@main
struct raceAppApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task {
                    model.onLaunch()
                    #if DEBUG
                    DemoSessionSeeder.runIfRequested(model)
                    DemoSessionSeeder.runPresentationIfRequested(model)
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
