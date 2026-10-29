//
//  RaceAppWidgetBundle.swift
//  raceAppWidgets
//
//  Widget extension entry point. Only the recording Live Activity for now.
//

import SwiftUI
import WidgetKit

@main
struct RaceAppWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
