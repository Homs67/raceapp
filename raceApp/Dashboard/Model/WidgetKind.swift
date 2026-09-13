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
    // Phase 1 — Lap Timer dashboard
    case lapTime, lapDelta, lapMap, lastLap, bestLap
    // Placeholder for kinds a newer build wrote that this one doesn't know
    case unknown

    /// Kinds offered in the library (everything except the placeholder).
    static var library: [WidgetKind] { allCases.filter { $0 != .unknown } }

    var title: String {
        switch self {
        case .lapTime: return "Lap time"
        case .lapDelta: return "Delta"
        case .lapMap: return "Lap"
        case .lastLap: return "Last lap"
        case .bestLap: return "Best lap"
        case .unknown: return "Unavailable"
        }
    }

    var libraryDescription: String {
        switch self {
        case .lapTime: return "Running time of the current lap"
        case .lapDelta: return "Ahead or behind your best lap, live"
        case .lapMap: return "Lap number with your position on the track"
        case .lastLap: return "Time of the lap you just completed"
        case .bestLap: return "Fastest lap this session"
        case .unknown: return ""
        }
    }

    var category: WidgetCategory {
        switch self {
        case .lapTime, .lapDelta, .lapMap, .lastLap, .bestLap: return .lapTiming
        case .unknown: return .status
        }
    }

    var supportedSizes: [WidgetSize] {
        switch self {
        case .lapTime: return [.small, .medium, .large]
        case .lapDelta: return [.small, .medium]
        case .lapMap: return [.small, .medium, .large]
        case .lastLap, .bestLap: return [.small, .medium]
        case .unknown: return [.small]
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .lapTime, .lapDelta: return .medium
        default: return .small
        }
    }

    /// Hero widgets show their value at 100 pt in medium/large; everything
    /// else stays at 48 pt in every size (a bigger cell means more room, never
    /// bigger text).
    var isHero: Bool {
        switch self {
        case .lapTime, .lapDelta: return true
        default: return false
        }
    }

    var libraryIcon: String {
        switch self {
        case .lapTime: return "stopwatch"
        case .lapDelta: return "plusminus"
        case .lapMap: return "map"
        case .lastLap: return "arrow.uturn.backward"
        case .bestLap: return "trophy"
        case .unknown: return "questionmark"
        }
    }

    /// Cap per dashboard (camera preview later = 1); nil = unlimited.
    var maxPerDashboard: Int? { nil }
}
