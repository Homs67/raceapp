//
//  DeviceLinkStatus.swift
//  raceApp
//
//  What a device link looks like to someone who is not debugging it.
//

import SwiftUI
import BleKit
import ObdKit
import RaceBoxKit
import SessionKit

/// Four states, one line, one optional second line.
///
/// Both links report far more than four states — `ObdConnectionState` has ten
/// and `RaceBoxController.State` five, each with its own wording — and Settings
/// used to render every one of them. But the driver is asking one question: is
/// this working right now, and if not, what do I do? Everything collapses onto
/// the four kinds below. The mapping lives here, in two pure functions, so it
/// can be read in one sitting and tested without a car or an adapter.
struct DeviceLinkStatus: Equatable {

    enum Kind: Equatable {
        /// Never paired. The card is an invitation, not a status.
        case notSetUp
        /// Scanning, connecting, reconnecting — anything in motion.
        case searching
        /// Data is flowing, or would be the moment the car wakes up.
        case connected
        /// Was paired once; not here now.
        case notConnected
    }

    var kind: Kind
    /// The status line. Short enough to sit in a pill.
    var line: String
    /// The one physical thing to do about it, when there is one.
    var sub: String?
    /// Something wants the driver: a sagging rail, an ignition still off.
    var attention = false

    var dot: Color {
        if attention { return .accent }
        switch kind {
        case .notSetUp: return .mutedWeak
        case .searching: return .accent
        case .connected: return .linkGreen
        case .notConnected: return .muted
        }
    }

    var isBusy: Bool { kind == .searching }

    /// The device pages show a single pill, so a short instruction wins over
    /// the state — "Turn the key to ON" says more than "Car off". A longer
    /// one is a sentence, not a label, and goes under the pill instead.
    var pill: String {
        guard let sub, sub.count <= 24 else { return line }
        return sub
    }

    /// Whatever the pill could not carry.
    var note: String? {
        guard let sub, sub.count > 24 else { return nil }
        return sub
    }

    /// The Settings cards are 177 pt wide, which fits a status word and not a
    /// sentence — so the line splits at its separators.
    var headline: String { line.components(separatedBy: " · ").first ?? line }

    /// Whatever the headline left behind: "25 Hz · 12.4 V", or the sub-line
    /// when the status was a single word to begin with.
    var detail: String? {
        let rest = line.components(separatedBy: " · ").dropFirst()
        return rest.isEmpty ? sub : rest.joined(separator: " · ")
    }
}

// MARK: - RaceBox

extension DeviceLinkStatus {

    /// Pure mapping, so the table above can be checked in a unit test.
    static func raceBox(state: RaceBoxController.State,
                        radio: BluetoothRadioState,
                        hasStoredDevice: Bool,
                        userDisconnected: Bool,
                        dataStalled: Bool,
                        hz: Double?,
                        power: LoggerPower?) -> DeviceLinkStatus {
        // Both devices talk over the same radio, so both say the same thing
        // when it is off. Nothing can happen until it is on, whatever the
        // link was doing a moment ago.
        if let off = radioOff(radio) { return off }

        switch state {
        case .idle:
            if userDisconnected { return .init(kind: .notConnected, line: "Disconnected") }
            guard hasStoredDevice else {
                return .init(kind: .notSetUp, line: "Set up RaceBox")
            }
            return .init(kind: .notConnected, line: "Not connected")

        case .scanning:
            return .init(kind: .searching, line: "Looking for RaceBox…")

        case .connecting:
            return .init(kind: .searching, line: "Connecting…")

        case .connected:
            var parts = ["Connected"]
            if let hz, hz >= 1 { parts.append("\(Int(hz.rounded())) Hz") }
            // The Micro has no battery — it reports whichever rail it sees, so
            // this is a voltage far more often than a percentage.
            if let power { parts.append(power.shortText) }
            // Green whenever the link is up. The rail voltage is reported in
            // the line and on the device page's Power tile; it is a reading,
            // not an alarm, and colouring "Connected" amber over it just made
            // a working logger look broken.
            return .init(kind: .connected,
                         line: parts.joined(separator: " · "),
                         sub: dataStalled ? "No data for 5 s" : nil,
                         attention: dataStalled)

        case .failed:
            // The reason is for the log, not the card. After a minute the
            // controller drops back to idle and this goes quiet by itself.
            return .init(kind: .notConnected, line: "Couldn’t connect", attention: true)
        }
    }

    static func raceBox(_ rb: RaceBoxController) -> DeviceLinkStatus {
        raceBox(state: rb.state,
                radio: rb.isSimulated ? .poweredOn : rb.bluetoothRadio,   // demo link: no radio involved
                hasStoredDevice: rb.storedDeviceName != nil,
                userDisconnected: rb.userDisconnected,
                dataStalled: rb.dataStalled,
                hz: rb.stats.measuredHz,
                power: rb.loggerPower)
    }
}

// MARK: - OBD-II

extension DeviceLinkStatus {

    static func obd(status: OBDAdapterUIStatus,
                    radio: BluetoothRadioState = .poweredOn,
                    hasStoredAdapter: Bool,
                    userDisconnected: Bool = false,
                    pidCount: Int,
                    failureIsFresh: Bool = false) -> DeviceLinkStatus {
        // Read the radio directly rather than through `OBDAdapterUIStatus`,
        // which flattens off / unauthorised / unsupported into one case — the
        // two devices would otherwise word the same situation differently.
        // A switched-off radio is also not a failure, so the error below must
        // not colour it.
        if let off = radioOff(radio) { return off }
        if case .bluetoothOff = status { return radioOff(.poweredOff)! }
        // Checked before the status, because after a disconnect the machine
        // sits at idle and `adapterUIStatus` reports that as "finding" even
        // though nothing is looking for anything.
        if userDisconnected { return .init(kind: .notConnected, line: "Disconnected") }

        var result = base(status: status, hasStoredAdapter: hasStoredAdapter,
                          pidCount: pidCount)
        // A failure that just happened is worth a colour; one from an hour ago
        // is not. The controller lets it go quiet after a minute.
        if failureIsFresh, result.kind == .notConnected { result.attention = true }
        return result
    }

    private static func base(status: OBDAdapterUIStatus,
                             hasStoredAdapter: Bool,
                             pidCount: Int) -> DeviceLinkStatus {
        switch status {
        case .bluetoothOff:
            return radioOff(.poweredOff)!   // handled above; here for exhaustiveness

        case .finding:
            return .init(kind: .searching, line: "Looking for the adapter…")

        case .found(let adapters):
            let line = adapters.count == 1
                ? "Found \(adapters[0].name) · tap to connect"
                : "Found \(adapters.count) devices"
            return .init(kind: .searching, line: line)

        case .notFound:
            guard hasStoredAdapter else {
                return .init(kind: .notSetUp, line: "Set up OBD-II")
            }
            return .init(kind: .notConnected, line: "Not connected")

        case .connecting:
            return .init(kind: .searching, line: "Connecting…")

        case .reconnecting:
            return .init(kind: .searching, line: "Reconnecting…")

        case .connected(_, waitingForIgnition: true):
            return .init(kind: .connected,
                         line: "Car off",
                         sub: "Turn the key to ON",
                         attention: true)

        case .connected(_, waitingForIgnition: false):
            return .init(kind: .connected,
                         line: pidCount > 0 ? "Connected · \(pidCount) PIDs" : "Connected")
        }
    }

    static func obd(_ c: ConnectionController) -> DeviceLinkStatus {
        obd(status: c.adapterUIStatus,
            radio: c.isDemo ? .poweredOn : c.bluetoothRadio,   // demo adapter: no radio involved
            hasStoredAdapter: c.hasStoredAdapter,
            userDisconnected: c.userDisconnected,
            pidCount: c.supportedPidCount,
            failureIsFresh: c.failureIsFresh)
    }
}

// MARK: - Shared

extension DeviceLinkStatus {

    /// The radio is off, unauthorised or missing: the same answer for every
    /// device, and grey rather than red — nothing is broken, there is just a
    /// switch to flick.
    static func radioOff(_ radio: BluetoothRadioState) -> DeviceLinkStatus? {
        switch radio {
        case .poweredOff:
            return .init(kind: .notConnected, line: "Bluetooth is off")
        case .unauthorized:
            return .init(kind: .notConnected, line: "Bluetooth not allowed")
        case .unsupported:
            return .init(kind: .notConnected, line: "Bluetooth unavailable")
        case .unknown, .poweredOn:
            return nil
        }
    }

}
