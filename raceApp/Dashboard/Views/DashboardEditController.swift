//
//  DashboardEditController.swift
//  raceApp
//
//  Edit-mode state for one dashboard: a working copy, the drag in progress,
//  and which sheet is up. Every mutation is validated against BOTH
//  orientations — area ≤ 8 does not guarantee fit.
//

import SwiftUI
import Observation

@MainActor @Observable
final class DashboardEditController {

    struct Drag: Equatable {
        var id: UUID
        var translation: CGSize
        var lastIndex: Int?
    }

    enum Sheet: Identifiable, Equatable {
        case options(UUID)
        case library(insertAt: Int)
        var id: String {
            switch self {
            case .options(let id): return "options-\(id)"
            case .library(let i): return "library-\(i)"
            }
        }
    }

    private(set) var working: Dashboard

    nonisolated deinit {}   // see DashboardStore
    private(set) var dragging: Drag?
    var sheet: Sheet?
    /// Set when a mutation was refused because it wouldn't fit.
    var lastRejection: String?

    init(dashboard: Dashboard) {
        working = dashboard
    }

    func rename(_ name: String) {
        working.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? working.name : name
    }

    // MARK: - Mutations

    func remove(id: UUID) {
        withAnimation(.snappy(duration: 0.25)) {
            working.placements.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func resize(id: UUID, to size: WidgetSize) -> Bool {
        var trial = working.placements
        guard let i = trial.firstIndex(where: { $0.id == id }) else { return false }
        trial[i].size = size
        return commitIfFits(trial, failure: "\(size.label) doesn't fit on this dashboard")
    }

    @discardableResult
    func replace(id: UUID, with kind: WidgetKind) -> Bool {
        var trial = working.placements
        guard let i = trial.firstIndex(where: { $0.id == id }) else { return false }
        let size = kind.supportedSizes.contains(trial[i].size) ? trial[i].size : kind.defaultSize
        trial[i] = WidgetPlacement(id: trial[i].id, kind: kind, size: size)
        return commitIfFits(trial, failure: "\(kind.title) doesn't fit here")
    }

    @discardableResult
    func add(kind: WidgetKind, size: WidgetSize, at index: Int) -> Bool {
        if let cap = kind.maxPerDashboard,
           working.placements.filter({ $0.kind == kind }).count >= cap {
            lastRejection = "Only \(cap) \(kind.title) per dashboard"
            return false
        }
        var trial = working.placements
        trial.insert(WidgetPlacement(kind: kind, size: size), at: min(index, trial.count))
        return commitIfFits(trial, failure: "No room for \(kind.title) — remove or shrink a widget")
    }

    /// Sizes of `kind` that would fit if it replaced / were added.
    func fittingSizes(for kind: WidgetKind, replacing id: UUID?) -> [WidgetSize] {
        kind.supportedSizes.filter { size in
            var trial = working.placements
            if let id, let i = trial.firstIndex(where: { $0.id == id }) {
                trial[i] = WidgetPlacement(id: id, kind: kind, size: size)
            } else {
                trial.append(WidgetPlacement(kind: kind, size: size))
            }
            return GridPacker.fits(trial, grid: working.grid)
        }
    }

    private func commitIfFits(_ trial: [WidgetPlacement], failure: String) -> Bool {
        guard GridPacker.fits(trial, grid: working.grid) else {
            lastRejection = failure
            return false
        }
        withAnimation(.snappy(duration: 0.25)) { working.placements = trial }
        lastRejection = nil
        return true
    }

    // MARK: - Press → tap / lift / drag

    /// How long a still finger rests on a widget before it lifts.
    static let liftDelay: Duration = .milliseconds(250)
    /// Movement before the lift that turns the press into a scroll, not a tap.
    private static let tapSlop: CGFloat = 10

    private struct Press {
        let id: UUID
        var moved = false
    }
    private var press: Press?
    private var liftTask: Task<Void, Never>?

    func pressChanged(id: UUID, translation: CGSize, unit: (x: Double, y: Double),
                      stretched: [UUID: UnitRect]) {
        if press == nil {
            press = Press(id: id)
            liftTask?.cancel()
            liftTask = Task { [weak self] in
                try? await Task.sleep(for: Self.liftDelay)
                guard let self, !Task.isCancelled, let press = self.press,
                      press.id == id, !press.moved else { return }
                self.dragBegan(id: id)
            }
        }
        if dragging?.id == id {
            dragChanged(id: id, translation: translation, unit: unit, stretched: stretched)
        } else if hypot(translation.width, translation.height) > Self.tapSlop {
            press?.moved = true   // wandered before the lift: neither tap nor drag
            liftTask?.cancel()
        }
    }

    func pressEnded(id: UUID) {
        liftTask?.cancel()
        liftTask = nil
        let wasTap = press?.id == id && press?.moved == false && dragging == nil
        press = nil
        if dragging != nil {
            dragEnded()
        } else if wasTap {
            presentOptions(for: id)
        }
    }

    // MARK: - Drag to reorder

    func dragBegan(id: UUID) {
        guard dragging == nil else { return }
        dragging = Drag(id: id, translation: .zero, lastIndex: nil)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func dragChanged(id: UUID, translation: CGSize, unit: (x: Double, y: Double),
                     stretched: [UUID: UnitRect]) {
        if dragging == nil { dragBegan(id: id) }
        dragging?.translation = translation
        let target = GridPacker.insertionIndex(forUnitX: unit.x, unitY: unit.y, stretched: stretched,
                                               order: working.placements, dragging: id)
        guard target != dragging?.lastIndex else { return }
        dragging?.lastIndex = target
        var trial = working.placements
        guard let from = trial.firstIndex(where: { $0.id == id }) else { return }
        let item = trial.remove(at: from)
        trial.insert(item, at: min(target, trial.count))
        // Only reflow into arrangements that fit both ways; otherwise leave the
        // order alone and let the drop spring back.
        if GridPacker.fits(trial, grid: working.grid) {
            withAnimation(.snappy(duration: 0.25)) { working.placements = trial }
        }
    }

    func dragEnded() {
        guard dragging != nil else { return }
        withAnimation(.snappy(duration: 0.3)) { dragging = nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Sheets

    func presentOptions(for id: UUID) {
        guard dragging == nil else { return }
        sheet = .options(id)
    }

    func presentLibrary(insertAtUnit unit: (x: Double, y: Double), stretched: [UUID: UnitRect]) {
        let index = GridPacker.insertionIndex(forUnitX: unit.x, unitY: unit.y, stretched: stretched,
                                              order: working.placements, dragging: nil)
        sheet = .library(insertAt: index)
    }

    func presentLibraryAppending() {
        sheet = .library(insertAt: working.placements.count)
    }
}
