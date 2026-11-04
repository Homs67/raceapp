//
//  DeviceCard.swift
//  raceApp
//
//  The Settings entry point for one device: a picture of your hardware and
//  one line about it.
//

import SwiftUI

/// A device as it appears at the top of Settings.
///
/// Deliberately narrow in what it can say: artwork, name, one status word and
/// one detail line. Everything the old status card showed — adapter names,
/// RSSI, protocol, satellites, buttons for every branch of the state machine —
/// now lives on the device page behind this.
struct DeviceCard: View {

    let title: String
    let artwork: String
    let status: DeviceLinkStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(artwork)
                .resizable()
                .scaledToFit()
                .frame(height: 102)
                .frame(maxWidth: .infinity)
                // A device that is not here reads as absent, not broken.
                .opacity(status.kind == .connected ? 1 : 0.55)
                .padding(.top, 18)

            Text(title)
                .font(.sofia(20, .bold))
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 10)

            HStack(spacing: 6) {
                StatusDot(color: status.dot, pulsing: status.isBusy)
                Text(status.headline)
                    .font(.system(size: 13))
                    .foregroundStyle(status.kind == .connected && !status.attention
                                     ? Color.linkGreen : status.dot)
                    .lineLimit(1)
            }
            .padding(.top, 6)

            Text(status.detail ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status.headline)")
    }
}

/// The one dot every device status shares. Breathes while something is in
/// flight, so "searching" does not need the word.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing && on ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : .default,
                       value: on)
            .onAppear { on = pulsing }
            .onChange(of: pulsing) { _, now in on = now }
    }
}
