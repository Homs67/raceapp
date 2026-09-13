//
//  Dashboard.swift
//  raceApp
//
//  A dashboard is an ordered list of sized widgets. Placement order is reading
//  order; the packer turns it into cell frames for whichever grid the current
//  orientation has. Nothing here knows about points or views.
//

import Foundation

struct WidgetPlacement: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var kind: WidgetKind
    var size: WidgetSize
    /// Reserved for per-widget options (delta reference, redline…) so adding
    /// one later never needs a file migration.
    var settings: [String: String]

    init(id: UUID = UUID(), kind: WidgetKind, size: WidgetSize, settings: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.size = size
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case id, kind, size, settings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // A retired widget kind must not fail the whole dashboards file; it
        // decodes to `.unknown` and the store filters it out.
        kind = WidgetKind(rawValue: try c.decode(String.self, forKey: .kind)) ?? .unknown
        size = try c.decode(WidgetSize.self, forKey: .size)
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(size, forKey: .size)
        if !settings.isEmpty { try c.encode(settings, forKey: .settings) }
    }
}

struct Dashboard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var grid: GridSpec
    var placements: [WidgetPlacement]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, grid: GridSpec = .base,
         placements: [WidgetPlacement], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.grid = grid
        self.placements = placements
        self.createdAt = createdAt
    }

    static let maxCount = 6

    /// Figma 125:4704 — row 1 lap time + delta (medium each), row 2 lap+map,
    /// last, best (small each, stretched to thirds).
    static func lapTimer() -> Dashboard {
        Dashboard(name: "Lap Timer", placements: [
            WidgetPlacement(kind: .lapTime, size: .medium),
            WidgetPlacement(kind: .lapDelta, size: .medium),
            WidgetPlacement(kind: .lapMap, size: .small),
            WidgetPlacement(kind: .lastLap, size: .small),
            WidgetPlacement(kind: .bestLap, size: .small),
        ])
    }

    /// Both orientations must pack without overflow.
    var fitsEverywhere: Bool { GridPacker.fits(placements, grid: grid) }
}
