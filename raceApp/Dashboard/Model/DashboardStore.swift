//
//  DashboardStore.swift
//  raceApp
//
//  Persists dashboards as one JSON file beside the session store. Seeds the
//  defaults on first launch; never fails the whole file over one retired
//  widget kind.
//

import Foundation
import SwiftUI

@MainActor @Observable
final class DashboardStore {

    private(set) var dashboards: [Dashboard] = []
    var selectedId: UUID? {
        didSet { if selectedId != oldValue { save() } }
    }

    private let fileURL: URL

    /// The back-deployed isolated deinit for @MainActor classes (iOS 17
    /// target) aborts in the malloc shim when the object is released. Nothing
    /// here needs the main actor to tear down.
    nonisolated deinit {}
    private static let schemaVersion = 1
    /// Old faces preference — meaningless now; removed on first load.
    private static let legacyFaceKey = "dashboardFace"

    /// Bumped when a new default dashboard should be offered to existing
    /// installs (appended once, never replacing what the user built).
    private static let seedVersion = 2

    private struct File: Codable {
        var schemaVersion: Int
        var seedVersion: Int?
        var selectedId: UUID?
        var dashboards: [Dashboard]
    }

    nonisolated static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("LiveData", isDirectory: true)
            .appendingPathComponent("dashboards.json")
    }

    init(fileURL: URL = DashboardStore.defaultURL()) {
        self.fileURL = fileURL
        load()
    }

    var selected: Dashboard? {
        dashboards.first { $0.id == selectedId } ?? dashboards.first
    }

    var selectedIndex: Int {
        dashboards.firstIndex { $0.id == selectedId } ?? 0
    }

    func dashboard(id: UUID) -> Dashboard? { dashboards.first { $0.id == id } }

    // MARK: - Mutations (every one validates + saves)

    @discardableResult
    func add(_ dashboard: Dashboard) -> Bool {
        guard dashboards.count < Dashboard.maxCount, dashboard.fitsEverywhere else { return false }
        dashboards.append(dashboard)
        if selectedId == nil { selectedId = dashboard.id }
        save()
        return true
    }

    func update(_ dashboard: Dashboard) {
        guard let i = dashboards.firstIndex(where: { $0.id == dashboard.id }) else { return }
        dashboards[i] = dashboard
        save()
    }

    func remove(id: UUID) {
        dashboards.removeAll { $0.id == id }
        if dashboards.isEmpty { dashboards = Self.seed() }
        if selectedId == id || selectedId == nil { selectedId = dashboards.first?.id }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        dashboards.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    @discardableResult
    func duplicate(id: UUID) -> Dashboard? {
        guard let source = dashboard(id: id), dashboards.count < Dashboard.maxCount else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        copy.createdAt = Date()
        copy.placements = source.placements.map { p in
            var q = p; q.id = UUID(); return q
        }
        if let i = dashboards.firstIndex(where: { $0.id == id }) {
            dashboards.insert(copy, at: i + 1)
        } else {
            dashboards.append(copy)
        }
        save()
        return copy
    }

    func resetToDefaults() {
        dashboards = Self.seed()
        selectedId = dashboards.first?.id
        save()
    }

    static func seed() -> [Dashboard] {
        [Dashboard.lapTimer(), Dashboard.driving()]
    }

    // MARK: - Persistence

    func load() {
        UserDefaults.standard.removeObject(forKey: Self.legacyFaceKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let file = try? decoder.decode(File.self, from: data),
           !file.dashboards.isEmpty {
            dashboards = file.dashboards.map { d in
                var clean = d
                clean.placements.removeAll { $0.kind == .unknown }
                return clean
            }
            selectedId = file.selectedId.flatMap { id in dashboards.contains { $0.id == id } ? id : nil }
                ?? dashboards.first?.id
            if (file.seedVersion ?? 1) < Self.seedVersion {
                // v2 added Driving: give it to installs seeded before it.
                if !dashboards.contains(where: { $0.name == "Driving" }), dashboards.count < Dashboard.maxCount {
                    dashboards.append(Dashboard.driving())
                }
                save()
            }
        } else {
            dashboards = Self.seed()
            selectedId = dashboards.first?.id
            save()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = File(schemaVersion: Self.schemaVersion, seedVersion: Self.seedVersion,
                        selectedId: selectedId, dashboards: dashboards)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("dashboards.json write failed: \(error)")
        }
    }
}
