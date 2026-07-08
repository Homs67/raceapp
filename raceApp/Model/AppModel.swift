//
//  AppModel.swift
//  raceApp
//
//  Composition root: bus + store + connection + recording + phone sensors.
//

import Foundation
import SwiftUI
import SessionKit

@MainActor @Observable
final class AppModel {

    let bus = TelemetryBus()
    let store = SessionStore.standard()
    let connection: ConnectionController
    let recording: RecordingCoordinator
    let gearEstimator = GearEstimator()

    private let sensors = PhoneSensorSuite()
    private var launched = false

    init() {
        let bus = self.bus
        connection = ConnectionController(bus: bus)
        recording = RecordingCoordinator(store: store, bus: bus)
        connection.onObdLinkLost = { [recording] in
            recording.noteObdLinkLost()
        }
    }

    func onLaunch() {
        guard !launched else { return }
        launched = true
        recording.recoverAtLaunch()
        sensors.requestPermissions()
        sensors.start { [bus] channel, value, t in
            bus.publish(channel, value, at: t)
        }
        connection.onLaunch()
        #if DEBUG
        // Dev/screenshot hooks: `simctl launch ... -demo [-record] [-shift-demo]`
        if CommandLine.arguments.contains("-shift-demo") {
            UserDefaults.standard.set(true, forKey: "shiftEnabled")
            UserDefaults.standard.set(3000.0, forKey: "shiftRPM")
        }
        if CommandLine.arguments.contains("-demo") {
            connection.startDemo()
            if CommandLine.arguments.contains("-record") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    startRecording(metricUnits: false)
                }
            }
        }
        #endif
    }

    func startRecording(metricUnits: Bool) {
        Task {
            await recording.start(
                car: connection.carInfo,
                metricUnits: metricUnits,
                supportedPids: connection.supportedPidList
            )
        }
    }

    func stopRecording() {
        Task {
            await recording.stop()
        }
    }
}
