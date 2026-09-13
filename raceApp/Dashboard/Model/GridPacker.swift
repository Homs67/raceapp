//
//  GridPacker.swift
//  raceApp
//
//  Turns an ordered placement list into cell frames. Pure and deterministic so
//  portrait reflow, drag-reorder and "does it fit" are all the same function.
//
//  Two steps:
//  1. `pack` — first-fit in row-major order (a later small fills an earlier
//     hole, exactly like the iOS Home Screen).
//  2. `stretch` — widgets in a partially-filled row share that row's width, so
//     three smalls become thirds (Figma 125:4704 row 2). Multi-row widgets keep
//     their unit width; single-row widgets stretch within the free interval
//     they were packed into.
//

import Foundation

/// Integer cell rectangle from `pack`.
struct GridRect: Equatable, Hashable {
    var row: Int
    var col: Int
    var rows: Int
    var cols: Int
}

/// Fractional unit rectangle from `stretch` (x/width may be non-integers).
struct UnitRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

struct PackResult: Equatable {
    var frames: [UUID: GridRect]
    var overflow: [UUID]
    var grid: GridSpec

    func isFree(row: Int, col: Int) -> Bool {
        !frames.values.contains { r in
            row >= r.row && row < r.row + r.rows && col >= r.col && col < r.col + r.cols
        }
    }

    var emptyCells: [(row: Int, col: Int)] {
        var cells: [(Int, Int)] = []
        for r in 0..<grid.rows { for c in 0..<grid.cols where isFree(row: r, col: c) { cells.append((r, c)) } }
        return cells
    }
}

enum GridPacker {

    static func pack(_ items: [WidgetPlacement], grid: GridSpec) -> PackResult {
        var occupied = [[Bool]](repeating: [Bool](repeating: false, count: grid.cols), count: grid.rows)
        var frames: [UUID: GridRect] = [:]
        var overflow: [UUID] = []

        for item in items {
            let (w, h) = item.size.span
            var placed = false
            scan: for r in 0...(max(0, grid.rows - h)) where r + h <= grid.rows {
                for c in 0...(max(0, grid.cols - w)) where c + w <= grid.cols {
                    var free = true
                    outer: for rr in r..<(r + h) {
                        for cc in c..<(c + w) where occupied[rr][cc] { free = false; break outer }
                    }
                    guard free else { continue }
                    for rr in r..<(r + h) { for cc in c..<(c + w) { occupied[rr][cc] = true } }
                    frames[item.id] = GridRect(row: r, col: c, rows: h, cols: w)
                    placed = true
                    break scan
                }
            }
            if !placed { overflow.append(item.id) }
        }
        return PackResult(frames: frames, overflow: overflow, grid: grid)
    }

    /// Both orientations pack without overflow.
    static func fits(_ items: [WidgetPlacement], grid: GridSpec = .base) -> Bool {
        pack(items, grid: grid).overflow.isEmpty && pack(items, grid: grid.transposed).overflow.isEmpty
    }

    /// Stretch single-row widgets across the free width of their row.
    static func stretch(_ result: PackResult) -> [UUID: UnitRect] {
        let grid = result.grid
        var out: [UUID: UnitRect] = [:]

        // Multi-row widgets are fixed; they also carve each row into intervals.
        for (id, r) in result.frames where r.rows > 1 {
            out[id] = UnitRect(x: Double(r.col), y: Double(r.row), width: Double(r.cols), height: Double(r.rows))
        }

        for row in 0..<grid.rows {
            let blocked = result.frames.values.filter { $0.rows > 1 && row >= $0.row && row < $0.row + $0.rows }
            // Free column intervals in this row.
            var intervals: [(start: Int, end: Int)] = []   // end exclusive
            var col = 0
            while col < grid.cols {
                if blocked.contains(where: { col >= $0.col && col < $0.col + $0.cols }) { col += 1; continue }
                let start = col
                while col < grid.cols, !blocked.contains(where: { col >= $0.col && col < $0.col + $0.cols }) { col += 1 }
                intervals.append((start, col))
            }
            let singles = result.frames
                .filter { $0.value.rows == 1 && $0.value.row == row }
                .sorted { $0.value.col < $1.value.col }

            for interval in intervals {
                let members = singles.filter { $0.value.col >= interval.start && $0.value.col < interval.end }
                guard !members.isEmpty else { continue }
                let units = members.reduce(0) { $0 + $1.value.cols }
                let width = Double(interval.end - interval.start)
                var x = Double(interval.start)
                for (id, r) in members {
                    let w = width * Double(r.cols) / Double(units)
                    out[id] = UnitRect(x: x, y: Double(row), width: w, height: 1)
                    x += w
                }
            }
        }
        return out
    }

    /// Where a widget dropped at `unit` point (fractional grid coords) should
    /// be inserted in `order` so packing lands it there or as close as
    /// row-major order allows.
    static func insertionIndex(forUnitX x: Double, unitY y: Double,
                               stretched: [UUID: UnitRect], order: [WidgetPlacement],
                               dragging: UUID?) -> Int {
        let others = order.filter { $0.id != dragging }
        // Over an existing widget: before it, or after it when its left half
        // is already behind us (standard swap feel).
        if let (id, rect) = stretched.first(where: { $0.key != dragging && $0.value.contains(x: x, y: y) }),
           let idx = others.firstIndex(where: { $0.id == id }) {
            return x < rect.midX ? idx : idx + 1
        }
        // Empty cell: first widget whose origin is row-major after the point.
        let row = Int(floor(y))
        for (i, item) in others.enumerated() {
            guard let r = stretched[item.id] else { continue }
            let itemRow = Int(r.y)
            if itemRow > row || (itemRow == row && r.x > x) { return i }
        }
        return others.count
    }
}
