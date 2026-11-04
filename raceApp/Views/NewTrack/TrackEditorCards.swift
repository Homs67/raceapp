//
//  TrackEditorCards.swift
//  raceApp
//
//  The floating cards of the line editor and the new-track flow
//  (Figma Track App → "New track flow — iteration 2"): one card shape,
//  a header of 44 pt pills (Cancel / title / Save-or-Next), the control in
//  the middle, 52 pt buttons at the bottom.
//

import SwiftUI
import UIKit

extension Color {
    /// Card fill and the two raised greys the cards use.
    static let editorCard = Color(hex: 0x1C1C1E)
    static let editorRaised = Color(hex: 0x2C2C2E)
    static let editorSelected = Color(hex: 0x48484A)
}

/// The rounded card floating over the bottom of a map.
struct EditorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.editorCard.opacity(0.96), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
            .padding(.horizontal, 8)
    }
}

/// A 44 pt capsule, the header's Cancel / Save / Next.
struct EditorPill: View {
    let label: String
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.mutedWeak)
                .padding(.horizontal, 16)
                .frame(minWidth: 84, minHeight: 44)
                .background(prominent && enabled ? Color.accent : Color.editorRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Header row: an optional leading pill or back chevron, the centered title,
/// an optional trailing pill.
struct EditorCardHeader: View {
    enum Leading {
        case none
        case back(() -> Void)
        case pill(String, () -> Void)
    }

    let title: String
    var leading: Leading = .none
    var trailing: (label: String, enabled: Bool, action: () -> Void)?

    var body: some View {
        ZStack {
            Text(title)
                .font(.sofia(22, .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 92)
            HStack {
                switch leading {
                case .none: EmptyView()
                case .back(let action):
                    Button(action: action) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 44, height: 44)
                            .background(Color.editorRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                case .pill(let label, let action):
                    EditorPill(label: label, action: action)
                }
                Spacer()
                if let trailing {
                    EditorPill(label: trailing.label, prominent: true, enabled: trailing.enabled, action: trailing.action)
                }
            }
        }
        .frame(height: 44)
    }
}

/// The 52 pt full-width button. With `detail` it shows a second line, the
/// way "Mark where I stand" names the device and its accuracy.
struct EditorBigButton: View {
    let label: String
    let symbol: String
    var detail: (text: String, symbol: String)?
    var prominent = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    Text(label).font(.system(size: detail == nil ? 16 : 15, weight: .semibold))
                }
                if let detail {
                    HStack(spacing: 4) {
                        Image(systemName: detail.symbol).font(.system(size: 10, weight: .semibold))
                        Text(detail.text).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.mutedStrong)
                }
            }
            .foregroundStyle(enabled ? Color.white : Color.mutedWeak)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(prominent && enabled ? Color.accent : Color.editorRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Placing a line: title, a short how-to, and the two ways to place it.
struct PlacingCard: View {
    let title: String
    let subtitle: String
    var onBack: (() -> Void)?
    let onPlace: () -> Void
    let markDetail: (text: String, symbol: String)
    let markEnabled: Bool
    let onMark: () -> Void

    var body: some View {
        EditorCard {
            EditorCardHeader(title: title, leading: onBack.map { .back($0) } ?? .none)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Color.mutedStrong)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 322)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 16)
            EditorBigButton(label: "Place here", symbol: "checkmark", action: onPlace)
            EditorBigButton(label: "Mark where I stand", symbol: "location.fill", detail: markDetail,
                            prominent: false, enabled: markEnabled, action: onMark)
                .padding(.top, 8)
        }
    }
}

// MARK: - Gate tools

enum GateTool: CaseIterable, Identifiable {
    case rotate, direction, width
    var id: Self { self }

    var title: String {
        switch self {
        case .rotate: return "Rotate"
        case .direction: return "Direction"
        case .width: return "Width"
        }
    }

    var symbol: String {
        switch self {
        case .rotate: return "arrow.clockwise"
        case .direction: return "arrow.up.arrow.down"
        case .width: return "arrow.left.and.right"
        }
    }
}

/// A placed line: header, the active tool's control, the tool tabs.
struct GateToolCard<Control: View>: View {
    let title: String
    let onCancel: () -> Void
    let trailing: (label: String, enabled: Bool, action: () -> Void)
    @Binding var tool: GateTool
    @ViewBuilder var control: Control

    var body: some View {
        EditorCard {
            EditorCardHeader(title: title, leading: .pill("Cancel", onCancel), trailing: trailing)
            control
                .frame(height: 116)
                .padding(.vertical, 8)
            GateToolTabs(selection: $tool)
        }
    }
}

struct GateToolTabs: View {
    @Binding var selection: GateTool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GateTool.allCases) { tool in
                let on = tool == selection
                Button { selection = tool } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.accent : Color.muted)
                        Text(tool.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.white : Color.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(on ? Color.editorSelected : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.editorRaised, in: Capsule())
    }
}

/// Heading as a horizontal ruler, like the straighten dial in Photos:
/// drag sideways to turn the line, 6 pt per degree, a tick every 5°.
struct RotationDial: View {
    @Binding var degrees: Double
    @State private var dragStart: Double?
    private let pointsPerDegree: CGFloat = 6
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 14) {
            Text("\(Int(degrees.rounded()) % 360)°")
                .font(.sofiaNumeral(46, .bold))
                .foregroundStyle(Color.textPrimary)
            Canvas { ctx, size in
                let mid = size.width / 2
                let span = Int(size.width / pointsPerDegree / 2) + 1
                let base = degrees.rounded(.down)
                for i in -span...span {
                    let d = base + Double(i)
                    let x = mid + CGFloat(d - degrees) * pointsPerDegree
                    let major = Int(d) % 5 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: major ? 6 : 12))
                    p.addLine(to: CGPoint(x: x, y: 24))
                    ctx.stroke(p, with: .color(major ? Color.white.opacity(0.75) : Color.white.opacity(0.3)),
                               lineWidth: major ? 1.6 : 1.2)
                }
                var c = Path()
                c.move(to: CGPoint(x: mid, y: 0))
                c.addLine(to: CGPoint(x: mid, y: 30))
                ctx.stroke(c, with: .color(.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let start = dragStart ?? degrees
                    if dragStart == nil { dragStart = start; haptic.prepare() }
                    let next = (start - Double(g.translation.width / pointsPerDegree)).truncatingRemainder(dividingBy: 360)
                    let wrapped = next < 0 ? next + 360 : next
                    if Int(wrapped / 5) != Int(degrees / 5) { haptic.selectionChanged() }
                    degrees = wrapped
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Heading")
            .accessibilityValue("\(Int(degrees.rounded())) degrees")
            .accessibilityAdjustableAction { dir in
                degrees = (degrees + (dir == .increment ? 1 : -1) + 360).truncatingRemainder(dividingBy: 360)
            }
        }
    }
}

/// Width as − value +, one metre per tap, a tick every 5 m.
struct WidthStepper: View {
    @Binding var meters: Double
    var range: ClosedRange<Double> = 4...60
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 0) {
            round("minus") { step(-1) }
            Text("\(Int(meters.rounded())) m")
                .font(.sofiaNumeral(46, .bold))
                .foregroundStyle(Color.textPrimary)
                .frame(minWidth: 146)
            round("plus") { step(1) }
        }
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 48, height: 48)
                .background(Color.editorRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }

    private func step(_ d: Double) {
        let next = min(max(meters.rounded() + d, range.lowerBound), range.upperBound)
        if Int(next) % 5 == 0 { haptic.impactOccurred() }
        meters = next
    }
}

/// Which way cars cross the line, as two explicit choices.
struct DirectionTiles: View {
    let labels: (String, String)
    let reversed: Bool
    let choose: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            tile(labels.0, symbol: "arrow.right", on: !reversed) { choose(false) }
            tile(labels.1, symbol: "arrow.left", on: reversed) { choose(true) }
        }
    }

    private func tile(_ label: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? Color.accent : Color.white)
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? Color.accent.opacity(0.14) : Color.editorRaised,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if on { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.accent, lineWidth: 2) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Map chrome

/// 44 pt round glass button over a map.
struct MapGlassButton: View {
    let symbol: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { MapGlassLabel(symbol: symbol, active: active) }
            .buttonStyle(.plain)
    }
}

struct MapGlassLabel: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(active ? Color.black : Color.white)
            .frame(width: 44, height: 44)
            .background(active ? Color.white : Color.editorCard.opacity(0.86), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

/// Two-line title capsule in the middle of the map's top bar.
struct MapTitleCapsule: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.sofia(18, .bold)).foregroundStyle(Color.textPrimary).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mutedStrong).lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .frame(minWidth: 180, minHeight: 44)
        .background(Color.editorCard.opacity(0.86), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}

/// The aiming mark for "Place here": a plain cross, no ghost line.
struct MapCrosshair: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.18)).frame(width: 44, height: 44)
            cross.stroke(Color.black.opacity(0.5), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            cross.stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            Circle().fill(Color.white).frame(width: 5, height: 5)
        }
        .frame(width: 44, height: 44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cross: Path {
        var p = Path()
        for (a, b) in [((2.0, 22.0), (16.0, 22.0)), ((28.0, 22.0), (42.0, 22.0)), ((22.0, 2.0), (22.0, 16.0)), ((22.0, 28.0), (22.0, 42.0))] {
            p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1))
        }
        return p
    }
}
