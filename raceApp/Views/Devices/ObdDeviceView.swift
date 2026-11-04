//
//  ObdDeviceView.swift
//  raceApp
//
//  The OBD-II adapter's page. Car off is not a page worth filling: the
//  adapter sits in the middle of the screen with one line under it, and the
//  health strip only exists once the car is talking.
//

import SwiftUI
import ObdKit
import SessionKit

struct ObdDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var connection: ConnectionController { model.connection }
    private var status: DeviceLinkStatus { .obd(connection) }
    /// Live data, not just an adapter link.
    private var live: Bool { connection.carLinkUp }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Group {
                if live {
                    ScrollView {
                        VStack(spacing: 0) {
                            topBar
                            adapter
                            liveBody
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    // Car off is not a page worth filling. The adapter sits in
                    // the middle of the screen and that is the whole page, so
                    // it centres rather than scrolls — and the top bar floats
                    // over it rather than pushing it down.
                    adapter
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .top) { topBar }
                        .padding(.horizontal, 16)
                }
            }
        }
        .background(Color.bgScreen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack {
            MapGlassButton(symbol: "chevron.left") { dismiss() }
            Spacer()
            Menu {
                NavigationLink(value: "help") { Label("Help", systemImage: "questionmark.circle") }
                if connection.hasStoredAdapter {
                    if connection.isDemo {
                        Button("Stop demo", role: .destructive) { connection.forget(); dismiss() }
                    } else {
                        Button("Disconnect") { connection.disconnectKeepingAdapter(); dismiss() }
                        Button("Forget this adapter", role: .destructive) {
                            connection.forget(); dismiss()
                        }
                    }
                }
            } label: {
                MapGlassLabel(symbol: "ellipsis")
            }
        }
        .padding(.top, 4)
    }

    private var adapter: some View {
        VStack(spacing: 0) {
            DeviceHero(dimmed: status.kind != .connected) {
                DeviceImageHero(artwork: "ObdAdapter", height: 204)
            }
            .frame(height: 204)
            .padding(.top, 8)

            DeviceTitleBlock(title: "OBD-II adapter",
                             subtitle: connection.storedAdapterName ?? "Veepeak BLE+",
                             status: status)
                .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var liveBody: some View {
        let snapshot = model.bus.snapshot()
        // The bus timestamps on monotonic uptime, not wall clock — asking with
        // an epoch `now` makes every reading look infinitely stale.
        let now = uptimeNow()

        DeviceSectionTitle(text: "Health")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            DeviceTile(icon: "minus.plus.batteryblock", label: "Car battery",
                       value: snapshot.fresh(.obd(.controlModuleVoltage), now: now, maxAge: 10)
                           .map { String(format: "%.1f V", $0) } ?? "—",
                       caption: nil)
            DeviceTile(icon: "point.3.connected.trianglepath.dotted", label: "Protocol",
                       value: connection.currentProtocol ?? "—",
                       caption: nil)
            DeviceTile(icon: "speedometer", label: "Refresh",
                       value: "\(Int(model.bus.obdHz(now: now).rounded())) Hz",
                       caption: nil)
            DeviceTile(icon: "list.bullet", label: "Supported",
                       value: connection.supportedPidCount > 0 ? "\(connection.supportedPidCount) PIDs" : "—",
                       caption: nil)
        }

        DeviceRowGroup {
            // The car itself lives in the garage on Profile — this is a
            // pointer to it, not a second place to edit one.
            DeviceRow(icon: "car.side", label: "My car", showsChevron: true) {
                Text(connection.carInfo.map { info in
                    [info.make, info.model].compactMap { $0 }.joined(separator: " ")
                } ?? model.garage.active?.title ?? "Not set")
            }
        }
        .padding(.top, 28)
    }
}
