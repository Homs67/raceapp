//
//  WidgetMetrics.swift
//  raceApp
//
//  The three type sizes and the chrome constants every widget shares. No
//  widget hard-codes a point size; `valueFont(kind:size:)` is the only place
//  a content size is chosen, and nothing scales text to fit.
//

import SwiftUI
import UIKit

enum WidgetMetrics {
    static let padding: CGFloat = 16
    static let titleSize: CGFloat = 21
    static let heroValueSize: CGFloat = 100
    static let valueSize: CGFloat = 48
    /// The grid runs to the screen edge, so the display's own corners do the
    /// rounding; only lifted widgets and gallery tiles use this.
    static let outerCornerRadius: CGFloat = 0
    static let panelCornerRadius: CGFloat = 8
    static let borderWidth: CGFloat = 1

    static var titleFont: Font { .sofia(titleSize, .heavy) }
    static let titleKerning: CGFloat = 2
    static let valueKerning: CGFloat = 1

    /// Hero widgets (lap time, delta, later rpm/speed) get 100 pt in medium and
    /// large; everything else, and heroes placed small, get 48 pt. A hero also
    /// drops to 48 when its widest possible string would not fit the cell —
    /// a portrait medium is 322 pt of content, and "0:00.00" at 100 pt is
    /// wider — so text is never scaled, only stepped between the two sizes.
    static func valueSize(kind: WidgetKind, size: WidgetSize, contentWidth: CGFloat) -> CGFloat {
        guard kind.isHero, size != .small else { return valueSize }
        return heroFits(kind: kind, width: contentWidth) ? heroValueSize : valueSize
    }

    static func valueFont(kind: WidgetKind, size: WidgetSize, contentWidth: CGFloat) -> Font {
        .sofiaNumeral(valueSize(kind: kind, size: size, contentWidth: contentWidth), .bold)
    }

    /// Widest string each hero can show, measured once with the real face and
    /// tabular figures so the rule tracks the font, not a guessed threshold.
    private static var heroWidthCache: [WidgetKind: CGFloat] = [:]

    static func heroFits(kind: WidgetKind, width: CGFloat) -> Bool {
        let needed = heroWidthCache[kind] ?? {
            let template = kind.heroTemplate
            let base = UIFont(name: SofiaFace.name(for: .bold), size: heroValueSize) ?? .boldSystemFont(ofSize: heroValueSize)
            let tabular = UIFont(descriptor: base.fontDescriptor.addingAttributes([
                .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
            ]), size: heroValueSize)
            let w = (template as NSString).size(withAttributes: [.font: tabular, .kern: valueKerning]).width
            heroWidthCache[kind] = w
            return w
        }()
        return needed <= width
    }

    static func valueColor(hero: Bool) -> Color { hero ? .white : .white.opacity(0.9) }
}

/// What a widget gets to render with. Passed by value — widgets never reach
/// for the bus, the model, or the environment for data.
struct WidgetContext {
    let placement: WidgetPlacement
    let contentSize: CGSize
    let isLandscape: Bool
    let live: LiveSnapshot
    let units: UnitsFormatter
    let isEditing: Bool
    let track: Track?

    var kind: WidgetKind { placement.kind }
    var size: WidgetSize { placement.size }
    var valueFont: Font { WidgetMetrics.valueFont(kind: kind, size: size, contentWidth: contentSize.width) }
    var isHeroSize: Bool {
        WidgetMetrics.valueSize(kind: kind, size: size, contentWidth: contentSize.width) == WidgetMetrics.heroValueSize
    }
}

/// A value line in the widget's type scale: 100/48 pt Sofia Bold, tabular,
/// one line, never scaled.
struct WidgetValue: View {
    let text: String
    let context: WidgetContext
    var color: Color?

    var body: some View {
        Text(text)
            .font(context.valueFont)
            .kerning(WidgetMetrics.valueKerning)
            .foregroundStyle(color ?? WidgetMetrics.valueColor(hero: context.isHeroSize))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Secondary line (48 pt) under or beside a hero value.
struct WidgetSecondaryValue: View {
    let text: String
    var color: Color = .white.opacity(0.9)

    var body: some View {
        Text(text)
            .font(.sofiaNumeral(WidgetMetrics.valueSize, .bold))
            .kerning(WidgetMetrics.valueKerning)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Small caption in the title style at a smaller size, for "vs best" etc.
struct WidgetCaption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.sofia(14, .heavy))
            .kerning(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
    }
}
