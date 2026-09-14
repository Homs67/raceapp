//
//  GridGeometry.swift
//  raceApp
//
//  Points for the grid: insets from the brief (24 top/bottom, 54 sides in
//  landscape), whole-point cell edges so 1 pt borders sit on pixels.
//

import SwiftUI

struct GridGeometry: Equatable {
    let grid: GridSpec
    let bounds: CGRect          // content area after insets
    let landscape: Bool

    static let landscapeInsets = (vertical: CGFloat(24), horizontal: CGFloat(54))
    static let portraitInsets = (vertical: CGFloat(24), horizontal: CGFloat(24))

    init(available: CGSize, grid: GridSpec, landscape: Bool, safeTop: CGFloat = 0, safeBottom: CGFloat = 0) {
        let insets = landscape ? Self.landscapeInsets : Self.portraitInsets
        // Top always clears the safe area (notch, or the nav bar while
        // editing). The landscape home indicator sits inside the 24 pt inset,
        // so only portrait reserves the bottom.
        let top = insets.vertical + safeTop
        let bottom = insets.vertical + (landscape ? 0 : safeBottom)
        let raw = CGRect(x: insets.horizontal, y: top,
                         width: available.width - 2 * insets.horizontal,
                         height: available.height - top - bottom)
        // Snap to whole points, absorbing the remainder into the insets.
        self.bounds = CGRect(x: raw.minX.rounded(), y: raw.minY.rounded(),
                             width: raw.width.rounded(.down), height: raw.height.rounded(.down))
        self.grid = grid.oriented(landscape: landscape)
        self.landscape = landscape
    }

    var unitWidth: CGFloat { bounds.width / CGFloat(grid.cols) }
    var unitHeight: CGFloat { bounds.height / CGFloat(grid.rows) }

    func frame(for rect: UnitRect) -> CGRect {
        let x0 = (bounds.minX + CGFloat(rect.x) * unitWidth).rounded()
        let x1 = (bounds.minX + CGFloat(rect.x + rect.width) * unitWidth).rounded()
        let y0 = (bounds.minY + CGFloat(rect.y) * unitHeight).rounded()
        let y1 = (bounds.minY + CGFloat(rect.y + rect.height) * unitHeight).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func frame(for cell: (row: Int, col: Int)) -> CGRect {
        frame(for: UnitRect(x: Double(cell.col), y: Double(cell.row), width: 1, height: 1))
    }

    /// Fractional grid coordinates of a point; nil outside the content area.
    func unitPoint(at p: CGPoint) -> (x: Double, y: Double)? {
        guard bounds.contains(p) else { return nil }
        return (Double((p.x - bounds.minX) / unitWidth), Double((p.y - bounds.minY) / unitHeight))
    }

    /// Nearest grid coordinates even when the point is outside (drag off-edge).
    func clampedUnitPoint(at p: CGPoint) -> (x: Double, y: Double) {
        let x = min(max(p.x, bounds.minX), bounds.maxX - 0.001)
        let y = min(max(p.y, bounds.minY), bounds.maxY - 0.001)
        return (Double((x - bounds.minX) / unitWidth), Double((y - bounds.minY) / unitHeight))
    }

    /// Corners of a cell that coincide with the dashboard's outer corners get
    /// the outer radius, so the group reads as one rounded panel.
    func outerCorners(of frame: CGRect) -> UnevenRoundedRectangle {
        let r = WidgetMetrics.outerCornerRadius
        let eps: CGFloat = 1.5
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < eps }
        let left = near(frame.minX, bounds.minX), right = near(frame.maxX, bounds.maxX)
        let top = near(frame.minY, bounds.minY), bottom = near(frame.maxY, bounds.maxY)
        return UnevenRoundedRectangle(
            topLeadingRadius: top && left ? r : 0,
            bottomLeadingRadius: bottom && left ? r : 0,
            bottomTrailingRadius: bottom && right ? r : 0,
            topTrailingRadius: top && right ? r : 0)
    }

    func cell(at p: CGPoint) -> (row: Int, col: Int)? {
        guard let u = unitPoint(at: p) else { return nil }
        return (Int(u.y), Int(u.x))
    }
}
