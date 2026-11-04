//
//  DevicePageParts.swift
//  raceApp
//
//  The pieces both device pages are built from.
//

import SwiftUI

/// Hero frame at the top of a device page.
///
/// Takes any content so the RaceBox can put a live SceneKit render here while
/// the OBD-II adapter — which has no model — puts a photograph.
struct DeviceHero<Content: View>: View {
    var dimmed = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(dimmed ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.35), value: dimmed)
    }
}

/// Artwork hero for a device we only have a picture of.
struct DeviceImageHero: View {
    let artwork: String
    var height: CGFloat = 260

    var body: some View {
        Image(artwork)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}

/// Device name, then the one status line. The pill carries the instruction
/// when there is one, so "Turn the key to ON" beats "Car off".
struct DeviceTitleBlock: View {
    let title: String
    let subtitle: String?
    let status: DeviceLinkStatus

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.sofia(34, .bold))
                .foregroundStyle(Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
            }
            HStack(spacing: 8) {
                StatusDot(color: status.dot, pulsing: status.isBusy)
                Text(status.pill)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(status.dot)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(status.dot.opacity(0.14), in: Capsule())
            .padding(.top, 2)

            if let note = status.note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One of the 2×2 health tiles: what it is, the number, and what the number
/// means.
struct DeviceTile: View {
    let icon: String
    let label: String
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accent)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedStrong)
            }
            Text(value)
                .font(.sofiaNumeral(26, .bold))
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 6)
            Text(caption ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Label, value, chevron — the grouped-rows shape used across the app.
struct DeviceRow<Trailing: View>: View {
    let icon: String
    let label: String
    var showsChevron = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.mutedStrong)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 8)
            trailing
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mutedWeak)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

extension DeviceRow where Trailing == EmptyView {
    init(icon: String, label: String, showsChevron: Bool = false) {
        self.init(icon: icon, label: label, showsChevron: showsChevron) { EmptyView() }
    }
}

/// The grouped container the rows sit in.
struct DeviceRowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct DeviceRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}

/// Section header, matching the track and profile pages.
struct DeviceSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.numeral(20, weight: .bold))
            .foregroundStyle(Color(hex: 0x8A8A8A))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }
}
