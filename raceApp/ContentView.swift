//
//  ContentView.swift
//  raceApp
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            HealthView()
                .tabItem { Label("Health", systemImage: "waveform.path.ecg") }
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
            ConnectionView()
                .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .tint(Color.textPrimary)
    }
}
