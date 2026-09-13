import XCTest
@testable import raceApp

final class GridPackerTests: XCTestCase {

    private func p(_ kind: WidgetKind, _ size: WidgetSize) -> WidgetPlacement {
        WidgetPlacement(kind: kind, size: size)
    }

    // MARK: - Lap Timer seed (Figma 125:4704)

    func testLapTimerPacksAsDesignedInLandscape() throws {
        let d = Dashboard.lapTimer()
        let packed = GridPacker.pack(d.placements, grid: .base)
        XCTAssertTrue(packed.overflow.isEmpty)
        let f = d.placements.map { packed.frames[$0.id]! }
        XCTAssertEqual(f[0], GridRect(row: 0, col: 0, rows: 1, cols: 2))   // lap time
        XCTAssertEqual(f[1], GridRect(row: 0, col: 2, rows: 1, cols: 2))   // delta
        XCTAssertEqual(f[2], GridRect(row: 1, col: 0, rows: 1, cols: 1))   // lap+map
        XCTAssertEqual(f[3], GridRect(row: 1, col: 1, rows: 1, cols: 1))   // last
        XCTAssertEqual(f[4], GridRect(row: 1, col: 2, rows: 1, cols: 1))   // best

        // Row 2 has three smalls in four columns → stretched to thirds.
        let s = GridPacker.stretch(packed)
        for i in 2...4 { XCTAssertEqual(s[d.placements[i].id]!.width, 4.0 / 3.0, accuracy: 1e-9) }
        XCTAssertEqual(s[d.placements[3].id]!.x, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s[d.placements[4].id]!.x, 8.0 / 3.0, accuracy: 1e-9)
        // Row 1 is full → no stretch.
        XCTAssertEqual(s[d.placements[0].id]!.width, 2)
        XCTAssertEqual(s[d.placements[1].id]!.x, 2)
    }

    func testLapTimerReflowsInPortrait() {
        let d = Dashboard.lapTimer()
        let packed = GridPacker.pack(d.placements, grid: GridSpec.base.transposed)
        XCTAssertTrue(packed.overflow.isEmpty)
        let f = d.placements.map { packed.frames[$0.id]! }
        XCTAssertEqual(f[0], GridRect(row: 0, col: 0, rows: 1, cols: 2))
        XCTAssertEqual(f[1], GridRect(row: 1, col: 0, rows: 1, cols: 2))
        XCTAssertEqual(f[2], GridRect(row: 2, col: 0, rows: 1, cols: 1))
        XCTAssertEqual(f[3], GridRect(row: 2, col: 1, rows: 1, cols: 1))
        XCTAssertEqual(f[4], GridRect(row: 3, col: 0, rows: 1, cols: 1))
        // Best lap alone on its row stretches to full width.
        let s = GridPacker.stretch(packed)
        XCTAssertEqual(s[d.placements[4].id]!.width, 2)
    }

    // MARK: - Packing rules

    func testLaterSmallFillsEarlierHole() {
        let items = [p(.lastLap, .small), p(.lapMap, .large), p(.bestLap, .small), p(.lapTime, .small), p(.lapDelta, .small)]
        let packed = GridPacker.pack(items, grid: .base)
        XCTAssertTrue(packed.overflow.isEmpty)
        XCTAssertEqual(packed.frames[items[0].id], GridRect(row: 0, col: 0, rows: 1, cols: 1))
        XCTAssertEqual(packed.frames[items[1].id], GridRect(row: 0, col: 1, rows: 2, cols: 2))
        XCTAssertEqual(packed.frames[items[2].id], GridRect(row: 0, col: 3, rows: 1, cols: 1))
        XCTAssertEqual(packed.frames[items[3].id], GridRect(row: 1, col: 0, rows: 1, cols: 1), "fills the hole under the first small")
        XCTAssertEqual(packed.frames[items[4].id], GridRect(row: 1, col: 3, rows: 1, cols: 1))
    }

    func testAreaWithinEightDoesNotGuaranteeFit() {
        // S + L + M + S = 8 units: packs in portrait, but the medium overflows in landscape.
        let items = [p(.lastLap, .small), p(.lapMap, .large), p(.lapTime, .medium), p(.bestLap, .small)]
        XCTAssertTrue(GridPacker.pack(items, grid: GridSpec.base.transposed).overflow.isEmpty)
        XCTAssertEqual(GridPacker.pack(items, grid: .base).overflow, [items[2].id])
        XCTAssertFalse(GridPacker.fits(items))
    }

    func testStretchKeepsLargeWidthAndSharesFreeIntervals() {
        // Row 0: [L(0-1)][A(2)][B(3)] is full; row 1: [L][C(2)][free] → C stretches over cols 2-3.
        let items = [p(.lapMap, .large), p(.lastLap, .small), p(.bestLap, .small), p(.lapTime, .small)]
        let packed = GridPacker.pack(items, grid: .base)
        XCTAssertEqual(packed.frames[items[3].id], GridRect(row: 1, col: 2, rows: 1, cols: 1))
        let s = GridPacker.stretch(packed)
        XCTAssertEqual(s[items[0].id], UnitRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(s[items[1].id], UnitRect(x: 2, y: 0, width: 1, height: 1))
        XCTAssertEqual(s[items[2].id], UnitRect(x: 3, y: 0, width: 1, height: 1))
        XCTAssertEqual(s[items[3].id], UnitRect(x: 2, y: 1, width: 2, height: 1))
    }

    func testStretchWithLargeMidRowKeepsIntervalsSeparate() {
        // Row 0: [A(0)][L(1-2)][B(3)] — full, nothing stretches; row 1: [C(0)][L][free(3)].
        let items = [p(.lastLap, .small), p(.lapMap, .large), p(.bestLap, .small), p(.lapTime, .small)]
        let packed = GridPacker.pack(items, grid: .base)
        XCTAssertEqual(packed.frames[items[3].id], GridRect(row: 1, col: 0, rows: 1, cols: 1))
        let s = GridPacker.stretch(packed)
        XCTAssertEqual(s[items[0].id]!.width, 1)
        XCTAssertEqual(s[items[2].id]!.width, 1)
        XCTAssertEqual(s[items[3].id]!.width, 1, "col 3 is a separate free interval, not stretched into")
        XCTAssertEqual(packed.emptyCells.map { [$0.row, $0.col] }, [[1, 3]])
    }

    // MARK: - Drop insertion

    func testInsertionIndexOverWidgetHalves() {
        let d = Dashboard.lapTimer()
        let packed = GridPacker.pack(d.placements, grid: .base)
        let s = GridPacker.stretch(packed)
        let dragging = d.placements[4].id   // best lap
        // Left half of lap time (index 0) → insert before it.
        XCTAssertEqual(GridPacker.insertionIndex(forUnitX: 0.3, unitY: 0.5, stretched: s, order: d.placements, dragging: dragging), 0)
        // Right half of delta (index 1) → after it.
        XCTAssertEqual(GridPacker.insertionIndex(forUnitX: 3.7, unitY: 0.5, stretched: s, order: d.placements, dragging: dragging), 2)
    }

    func testInsertionIndexOnEmptyCellAppendsInReadingOrder() {
        let items = [p(.lapTime, .medium), p(.lastLap, .small)]   // row 0: [M][S][free]
        let packed = GridPacker.pack(items, grid: .base)
        let s = GridPacker.stretch(packed)   // S stretches over cols 2-3 — so no empty cell in row 0
        // Row 1 is empty: dropping there appends.
        XCTAssertEqual(GridPacker.insertionIndex(forUnitX: 1, unitY: 1.5, stretched: s, order: items, dragging: nil), 2)
    }
}
