//
//  raceAppApp.swift
//  raceApp
//

import SwiftUI

@main
struct raceAppApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.onLaunch() }
        }
    }
}
