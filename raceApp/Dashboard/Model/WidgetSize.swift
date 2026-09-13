//
//  WidgetSize.swift
//  raceApp
//
//  Widget spans and the dashboard grid they pack into.
//

import Foundation

/// Cell span. Orientation-independent: a medium is 2 cells wide in the 4-column
/// landscape grid and full-width in the 2-column portrait grid.
enum WidgetSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var span: (cols: Int, rows: Int) {
        switch self {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .large: return (2, 2)
        }
    }

    var cellCount: Int { span.cols * span.rows }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// Grid shape in the landscape orientation; portrait is the transpose.
struct GridSpec: Codable, Equatable, Hashable {
    var rows: Int
    var cols: Int

    static let base = GridSpec(rows: 2, cols: 4)

    var transposed: GridSpec { GridSpec(rows: cols, cols: rows) }
    var cellCount: Int { rows * cols }

    func oriented(landscape: Bool) -> GridSpec { landscape ? self : transposed }
}
