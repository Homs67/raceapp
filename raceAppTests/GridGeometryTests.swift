import XCTest
import SwiftUI
@testable import raceApp

final class GridGeometryTests: XCTestCase {

    func testLandscapeFillsTheScreenPastTheIsland() {
        // iPhone 17 landscape: the island side carries a 59 pt inset.
        let g = GridGeometry(available: CGSize(width: 874, height: 402), grid: .base, landscape: true,
                             safe: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 0))
        XCTAssertEqual(g.bounds, CGRect(x: 59, y: 0, width: 815, height: 402))
        XCTAssertEqual(g.grid, GridSpec(rows: 2, cols: 4))
        let medium = g.frame(for: UnitRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(medium.width, 408)   // 815 / 2, rounded edges
        XCTAssertEqual(medium.height, 201)
        let third = g.frame(for: UnitRect(x: 4.0 / 3.0, y: 1, width: 4.0 / 3.0, height: 1))
        XCTAssertEqual(third.minX, 59 + 272)
    }

    func testPortraitTransposesAndKeepsOnlyTheTopClear() {
        let g = GridGeometry(available: CGSize(width: 402, height: 874), grid: .base, landscape: false,
                             safe: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0))
        XCTAssertEqual(g.grid, GridSpec(rows: 4, cols: 2))
        XCTAssertEqual(g.bounds.minX, 0)
        XCTAssertEqual(g.bounds.minY, 59)
        XCTAssertEqual(g.bounds.maxY, 874)
        XCTAssertEqual(g.bounds.width, 402)
    }

    func testEdgesAreWholePoints() {
        let g = GridGeometry(available: CGSize(width: 851.7, height: 393.2), grid: .base, landscape: true)
        for x in stride(from: 0.0, through: 4.0, by: 4.0 / 3.0) {
            let f = g.frame(for: UnitRect(x: x, y: 0, width: 1, height: 1))
            XCTAssertEqual(f.minX, f.minX.rounded())
            XCTAssertEqual(f.minY, f.minY.rounded())
        }
    }

    func testCellHitTesting() {
        let g = GridGeometry(available: CGSize(width: 874, height: 402), grid: .base, landscape: true,
                             safe: EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 0))
        XCTAssertNil(g.cell(at: CGPoint(x: 10, y: 10)))
        let c = g.cell(at: CGPoint(x: 59 + 204 * 3 + 10, y: 201 + 10))
        XCTAssertEqual(c?.row, 1)
        XCTAssertEqual(c?.col, 3)
        let clamped = g.clampedUnitPoint(at: CGPoint(x: 2000, y: -50))
        XCTAssertLessThan(clamped.x, 4)
        XCTAssertEqual(clamped.y, 0)
    }
}
