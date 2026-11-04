//
//  EmblemStyle.swift
//  raceApp
//
//  Every tunable value of the 3D track emblem: shape, materials, engraving,
//  lighting. The defaults are the shipped look; the debug playground
//  (Debug ▸ Emblem playground) edits a copy live and can save it as the
//  look the whole app uses.
//

import Foundation

enum EmblemShape: String, Codable, CaseIterable, Identifiable {
    case hexagon, hexagonFlat, circle, square, diamond, pentagon, octagon, triangle, shield, star, badge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hexagon: return "Hexagon"
        case .hexagonFlat: return "Hexagon (flat top)"
        case .circle: return "Circle"
        case .square: return "Rounded square"
        case .diamond: return "Diamond"
        case .pentagon: return "Pentagon"
        case .octagon: return "Octagon"
        case .triangle: return "Triangle"
        case .shield: return "Shield"
        case .star: return "Star"
        case .badge: return "Seal"
        }
    }
}

struct EmblemStyle: Codable, Equatable {
    // Shape
    var shape: EmblemShape = .hexagon
    /// Each track wears its own shape (from the catalogue) instead of `shape`.
    var shapePerTrack = true
    var depth: CGFloat = 0.05
    var innerScale: CGFloat = 0.93
    var outerCorner: CGFloat = 0.16
    var innerCorner: CGFloat = 0.14
    var rimRounding: CGFloat = 0.008
    var lipWidth: CGFloat = 0.018
    var lipHeight: CGFloat = 0.02
    var domeHeight: CGFloat = 0.10
    var domeHexness: CGFloat = 1
    var dishDepth: CGFloat = 0.06

    // Band
    var showBand = false
    var bandHeight: CGFloat = -0.40
    var bandSlope: CGFloat = 0.30
    var dividerWidth: CGFloat = 0.022
    var dividerHeight: CGFloat = 0.012

    // Track inlay
    var trackWidth: CGFloat = 0.040
    var trackHeight: CGFloat = 0.030
    var trackScale: CGFloat = 1
    var trackOffsetX: CGFloat = 0
    var trackOffsetY: CGFloat = 0

    // Track name on the front (off by default)
    var showFrontName = false
    var frontNameSize: CGFloat = 0.09
    var frontNameY: CGFloat = -0.62
    var frontNameSpacing: CGFloat = 0.12
    var frontNameHeight: CGFloat = 0.012
    var frontNameMaxWidth: CGFloat = 0.72
    var frontNameBold = true
    var frontNameCondensed = false

    // Rim and inlay metal
    var rimWhite: CGFloat = 0.95
    var rimMetalness: CGFloat = 1
    var rimRoughness: CGFloat = 0.14
    var inlayWhite: CGFloat = 0.98
    var inlayMetalness: CGFloat = 1
    var inlayRoughness: CGFloat = 0.08

    // Enamel face
    var enamelBrightness: CGFloat = 1
    var enamelMetalness: CGFloat = 0.5
    var enamelRoughness: CGFloat = 0.4
    var enamelGlow: CGFloat = 0.4
    var enamelClearCoat: CGFloat = 0

    // Band material
    var bandWhite: CGFloat = 0.86
    var bandMetalness: CGFloat = 0.85
    var bandRoughness: CGFloat = 0.48

    // Back and engraving
    var backWhite: CGFloat = 0.82
    var backMetalness: CGFloat = 1
    var backRoughness: CGFloat = 0.2
    var engraveDepth: CGFloat = 0.004
    var textSize: CGFloat = 0.072
    var letterSpacing: CGFloat = 0.14
    var textBold = false
    /// Metal brightness outside the letters (the letters are full brightness).
    var etchBase: CGFloat = 0.62

    // Lighting
    var envIntensity: CGFloat = 1.15
    var keyIntensity: CGFloat = 380
    var keyElevation: CGFloat = 0.6
    var keyAzimuth: CGFloat = 0.4
    var shadows = true
    var bloom: CGFloat = 0.25

    private static let key = "emblemStyle.v2"

    /// The saved look, or the defaults.
    static var saved: EmblemStyle {
        // Saved looks predate newer settings: lay them over the defaults so
        // they still load.
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = (try? JSONEncoder().encode(EmblemStyle()))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { _, new in new }),
              let style = try? JSONDecoder().decode(EmblemStyle.self, from: merged) else { return EmblemStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clearSaved() { UserDefaults.standard.removeObject(forKey: key) }

    /// Pretty JSON, for sharing a look.
    var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
