//
//  OBDAdapterUIStatus.swift
//  raceApp
//
//  User-facing OBD connection steps for Settings (and Debug previews).
//

import Foundation
import ObdKit

enum OBDAdapterUIStatus: Equatable, Identifiable {
    case bluetoothOff
    case finding
    case notFound
    case found([DiscoveredAdapter])
    case connecting(String)
    case connected(String, waitingForIgnition: Bool)
    case reconnecting(String)

    var id: String {
        switch self {
        case .bluetoothOff: "bluetoothOff"
        case .finding: "finding"
        case .notFound: "notFound"
        case .found(let adapters): "found-\(adapters.map(\.id.uuidString).joined(separator: ","))"
        case .connecting(let name): "connecting-\(name)"
        case .connected(let name, let waiting): "connected-\(name)-\(waiting)"
        case .reconnecting(let name): "reconnecting-\(name)"
        }
    }

    /// Debug / walkthrough catalog (stable order).
    static var previewCatalog: [OBDAdapterUIStatus] {
        let sample = DiscoveredAdapter(id: UUID(), name: "VEEPEAK", rssi: -55)
        return [
            .bluetoothOff,
            .finding,
            .notFound,
            .found([sample]),
            .connecting("VEEPEAK"),
            .connected("VEEPEAK", waitingForIgnition: true),
            .connected("VEEPEAK", waitingForIgnition: false),
            .reconnecting("VEEPEAK"),
        ]
    }

    var previewLabel: String {
        switch self {
        case .bluetoothOff: "1 · Bluetooth off"
        case .finding: "2 · Finding…"
        case .notFound: "3 · Not found"
        case .found: "4 · Found (Connect)"
        case .connecting: "5 · Connecting…"
        case .connected(_, true): "6a · Connected (ignition)"
        case .connected(_, false): "6b · Connected"
        case .reconnecting: "· Reconnecting…"
        }
    }
}
