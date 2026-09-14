//
//  WidgetKind.swift
//  raceApp
//
//  The widget library: every kind the dashboard can show, with the metadata
//  the editor and the grid need. Rendering lives in Dashboard/Widgets.
//

import Foundation

enum WidgetCategory: String, CaseIterable, Identifiable {
    case lapTiming, engine, dynamics, navigation, camera, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lapTiming: return "Lap timing"
        case .engine: return "Engine"
        case .dynamics: return "Dynamics"
        case .navigation: return "Track"
        case .camera: return "Camera"
        case .status: return "Status"
        }
    }
}

enum WidgetKind: String, CaseIterable {
    // Lap timing
    case lapTime, lapDelta, lapMap, lastLap, bestLap, predictedLap, sectorDelta, lapCount, sessionTime
    // Engine / driver inputs
    case rpm, speed, gear, shiftLights, pedals, coolant
    // Dynamics
    case gForce
    // Track / position
    case trackMap, altitude, heading
    // Status
    case status, raceBox
    // Camera
    case camera
    // Placeholder for kinds a newer build wrote that this one doesn't know
    case unknown

    /// Kinds offered in the library, in gallery order.
    static let library: [WidgetKind] = [
        .lapTime, .lapDelta, .predictedLap, .sectorDelta, .lapMap, .lastLap, .bestLap, .lapCount, .sessionTime,
        .rpm, .speed, .gear, .shiftLights, .pedals, .coolant,
        .gForce, .trackMap, .altitude, .heading,
        .status, .raceBox, .camera,
    ]

    var title: String {
        switch self {
        case .lapTime: return "Lap time"
        case .lapDelta: return "Delta"
        case .lapMap: return "Lap"
        case .lastLap: return "Last lap"
        case .bestLap: return "Best lap"
        case .predictedLap: return "Predicted"
        case .sectorDelta: return "Sectors"
        case .lapCount: return "Lap"
        case .sessionTime: return "Session"
        case .rpm: return "RPM"
        case .speed: return "Speed"
        case .gear: return "Gear"
        case .shiftLights: return "Shift"
        case .pedals: return "Pedals"
        case .coolant: return "Coolant"
        case .gForce: return "G-Force"
        case .trackMap: return "Track"
        case .altitude: return "Altitude"
        case .heading: return "Heading"
        case .status: return "Status"
        case .raceBox: return "RaceBox"
        case .camera: return "Camera"
        case .unknown: return "Unavailable"
        }
    }

    var category: WidgetCategory {
        switch self {
        case .lapTime, .lapDelta, .lapMap, .lastLap, .bestLap, .predictedLap, .sectorDelta, .lapCount, .sessionTime:
            return .lapTiming
        case .rpm, .speed, .gear, .shiftLights, .pedals, .coolant: return .engine
        case .gForce: return .dynamics
        case .trackMap, .altitude, .heading: return .navigation
        case .status, .raceBox, .unknown: return .status
        case .camera: return .camera
        }
    }

    var supportedSizes: [WidgetSize] {
        switch self {
        case .lapTime, .lapMap, .trackMap: return [.small, .medium, .large]
        case .lapDelta, .lastLap, .bestLap, .predictedLap, .lapCount, .sessionTime,
             .rpm, .speed, .pedals, .raceBox: return [.small, .medium]
        case .sectorDelta, .shiftLights: return [.medium]
        case .gForce: return [.medium, .large]
        case .gear, .coolant, .altitude, .heading, .status: return [.small]
        case .camera: return [.large]
        case .unknown: return [.small]
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .lapTime, .lapDelta, .predictedLap, .sectorDelta, .rpm, .speed, .shiftLights, .gForce: return .medium
        case .camera: return .large
        default: return .small
        }
    }

    /// Hero widgets show their value at 100 pt in medium/large; everything
    /// else stays at 48 pt in every size (a bigger cell means more room, never
    /// bigger text).
    var isHero: Bool {
        switch self {
        case .lapTime, .lapDelta, .predictedLap, .rpm, .speed: return true
        default: return false
        }
    }

    /// Widest string a hero can show, for the fits-at-100-pt check.
    var heroTemplate: String {
        switch self {
        case .lapTime, .predictedLap: return "0:00.00"
        case .lapDelta: return "+00.00"
        case .rpm: return "0000"
        case .speed: return "000"
        default: return "00000"
        }
    }

    /// Cap per dashboard (one camera preview); nil = unlimited.
    var maxPerDashboard: Int? { self == .camera ? 1 : nil }
}
