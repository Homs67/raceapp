import XCTest
@testable import raceApp

final class GridGeometryTests: XCTestCase {

    func testLandscapeMatchesFigmaFrame() {
        // Figma 125:4704: 874×402 frame, content at (54, 24) 766×354.
        let g = GridGeometry(available: CGSize(width: 874, height: 402), grid: .base, landscape: true)
        XCTAssertEqual(g.bounds, CGRect(x: 54, y: 24, width: 766, height: 354))
        XCTAssertEqual(g.grid, GridSpec(rows: 2, cols: 4))
        let medium = g.frame(for: UnitRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(medium.width, 383)
        XCTAssertEqual(medium.height, 177)
        let third = g.frame(for: UnitRect(x: 4.0 / 3.0, y: 1, width: 4.0 / 3.0, height: 1))
        XCTAssertEqual(third.minX, 54 + 255)
        XCTAssertEqual(third.width, 256)   // rounded edges: 309→565 vs 54+255.33/510.67
    }

    func testPortraitTransposesAndHonoursSafeArea() {
        let g = GridGeometry(available: CGSize(width: 402, height: 874), grid: .base, landscape: false,
                             safeTop: 59, safeBottom: 34)
        XCTAssertEqual(g.grid, GridSpec(rows: 4, cols: 2))
        XCTAssertEqual(g.bounds.minX, 24)
        XCTAssertEqual(g.bounds.minY, 24 + 59)
        XCTAssertEqual(g.bounds.maxY, 874 - 24 - 34)
        XCTAssertEqual(g.bounds.width, 354)
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
        let g = GridGeometry(available: CGSize(width: 874, height: 402), grid: .base, landscape: true)
        XCTAssertNil(g.cell(at: CGPoint(x: 10, y: 10)))
        let c = g.cell(at: CGPoint(x: 54 + 191 * 3 + 10, y: 24 + 177 + 10))
        XCTAssertEqual(c?.row, 1)
        XCTAssertEqual(c?.col, 3)
        let clamped = g.clampedUnitPoint(at: CGPoint(x: 2000, y: -50))
        XCTAssertLessThan(clamped.x, 4)
        XCTAssertEqual(clamped.y, 0)
    }
}
