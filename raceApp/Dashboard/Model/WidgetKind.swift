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
    case lapTime, lapDelta, lapMap, lastLap, bestLap, sectorDelta, sessionTime
    // Engine / driver inputs
    case rpm, speed, gear, shiftLights, pedals, coolant
    // Dynamics
    case gForce
    // Position
    case altitude, heading
    // Status
    case status
    // Camera
    case camera
    // Placeholder for kinds a newer build wrote that this one doesn't know
    case unknown
    /// A hole left where a widget was removed: keeps every other widget in
    /// place until the user moves something. Renders as nothing; in edit
    /// mode it's an add target.
    case empty

    /// Kinds offered in the library, in gallery order.
    static let library: [WidgetKind] = [
        .lapTime, .lapDelta, .sectorDelta, .lapMap, .lastLap, .bestLap, .sessionTime,
        .rpm, .speed, .gear, .shiftLights, .pedals, .coolant,
        .gForce, .altitude, .heading,
        .status, .camera,
    ]

    var title: String {
        switch self {
        case .lapTime: return "Lap time"
        case .lapDelta: return "Delta"
        case .lapMap: return "Lap"
        case .lastLap: return "Last lap"
        case .bestLap: return "Best lap"
        case .sectorDelta: return "Sectors"
        case .sessionTime: return "Session"
        case .rpm: return "RPM"
        case .speed: return "Speed"
        case .gear: return "Gear"
        case .shiftLights: return "Shift"
        case .pedals: return "Pedals"
        case .coolant: return "Coolant"
        case .gForce: return "G-Force"
        case .altitude: return "Altitude"
        case .heading: return "Heading"
        case .status: return "Status"
        case .camera: return "Camera"
        case .unknown: return "Unavailable"
        case .empty: return ""
        }
    }

    var category: WidgetCategory {
        switch self {
        case .lapTime, .lapDelta, .lapMap, .lastLap, .bestLap, .sectorDelta, .sessionTime:
            return .lapTiming
        case .rpm, .speed, .gear, .shiftLights, .pedals, .coolant: return .engine
        case .gForce: return .dynamics
        case .altitude, .heading: return .navigation
        case .status, .unknown, .empty: return .status
        case .camera: return .camera
        }
    }

    var supportedSizes: [WidgetSize] {
        switch self {
        case .lapTime, .lapMap: return [.small, .medium, .large]
        case .lapDelta, .lastLap, .bestLap, .sessionTime, .rpm, .speed, .pedals: return [.small, .medium]
        case .sectorDelta, .shiftLights: return [.medium]
        case .gForce: return [.medium, .large]
        case .gear, .coolant, .altitude, .heading, .status: return [.small]
        case .camera: return [.large]
        case .unknown: return [.small]
        case .empty: return WidgetSize.allCases
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .lapTime, .lapDelta, .sectorDelta, .rpm, .speed, .shiftLights, .gForce: return .medium
        case .camera: return .large
        default: return .small
        }
    }

    /// Hero widgets show their value at 100 pt in medium/large; everything
    /// else stays at 48 pt in every size (a bigger cell means more room, never
    /// bigger text).
    var isHero: Bool {
        switch self {
        case .lapTime, .lapDelta, .rpm, .speed: return true
        default: return false
        }
    }

    /// Widest string a hero can show, for the fits-at-100-pt check.
    var heroTemplate: String {
        switch self {
        case .lapTime: return "0:00.00"
        case .lapDelta: return "+00.00"
        case .rpm: return "0000"
        case .speed: return "000"
        default: return "00000"
        }
    }

    /// Cap per dashboard (one camera preview); nil = unlimited.
    var maxPerDashboard: Int? { self == .camera ? 1 : nil }
}
