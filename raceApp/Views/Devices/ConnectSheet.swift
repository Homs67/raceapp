//
//  ConnectSheet.swift
//  raceApp
//
//  First pairing, AirPods style: when a RaceBox is in range and has never
//  been set up, a card slides up with the device on it and one button. No
//  list to choose from — there is only ever one of yours.
//

import SwiftUI
import BleKit
import RaceBoxKit

struct ConnectSheet: View {
    let device: DiscoveredAdapter
    var onConnect: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.mutedStrong)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }

            if RaceBoxMesh.shell != nil {
                RaceBoxRenderView(pose: .angled, turntable: 28)
                    .frame(height: 220)
            } else {
                Image("RaceBoxHero")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 220)
            }

            Text(title)
                .font(.sofia(30, .bold))
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 8)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
                .padding(.top, 4)

            Button(action: onConnect) {
                Text("Connect")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 28)

            Button(action: onDismiss) {
                Text("Not now")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mutedStrong)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
        }
        .padding(20)
        .background(Color.bgSheet, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 8)
        .presentationBackground(.clear)
        .presentationDetents([.height(520)])
    }

    /// A RaceBox advertises as "RaceBox Micro 3242708836" — the model belongs
    /// in the title and the serial underneath, not all on one line.
    private var title: String {
        RaceBoxModel.parse(device.name)?.rawValue ?? device.name
    }

    private var subtitle: String {
        guard let model = RaceBoxModel.parse(device.name) else { return "Ready to pair" }
        let serial = device.name.dropFirst(model.rawValue.count)
            .trimmingCharacters(in: .whitespaces)
        return serial.isEmpty ? "Ready to pair" : serial + " · ready to pair"
    }
}
