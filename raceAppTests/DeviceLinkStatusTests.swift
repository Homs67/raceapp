import XCTest
import BleKit
import SessionKit
import SwiftUI
@testable import raceApp

/// The point of `DeviceLinkStatus` is that fifteen machine states become four
/// the driver can act on. These tests are that table, written down.
@MainActor
final class DeviceLinkStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - RaceBox

    private func raceBox(_ state: RaceBoxController.State,
                         radio: BluetoothRadioState = .poweredOn,
                         stored: Bool = true,
                         disconnected: Bool = false,
                         stalled: Bool = false,
                         hz: Double? = nil,
                         power: LoggerPower? = nil) -> DeviceLinkStatus {
        .raceBox(state: state, radio: radio, hasStoredDevice: stored,
                 userDisconnected: disconnected, dataStalled: stalled,
                 hz: hz, power: power)
    }

    func testNeverPairedInvitesSetup() {
        let s = raceBox(.idle, stored: false)
        XCTAssertEqual(s.kind, .notSetUp)
        XCTAssertEqual(s.line, "Set up RaceBox")
    }

    func testRememberedButAbsentIsPlainlyNotConnected() {
        let s = raceBox(.idle)
        XCTAssertEqual(s.kind, .notConnected)
        XCTAssertEqual(s.line, "Not connected")
        XCTAssertFalse(s.attention)
    }

    /// Pressing disconnect is not a problem, so it should not read like one.
    func testAManualDisconnectSaysSo() {
        XCTAssertEqual(raceBox(.idle, disconnected: true).line, "Disconnected")
        XCTAssertEqual(raceBox(.idle, disconnected: true).dot, Color.muted)
        XCTAssertEqual(obd(.notFound, disconnected: true).line, "Disconnected")
    }

    func testScanningAndConnectingAreBothSearching() {
        XCTAssertEqual(raceBox(.scanning).kind, .searching)
        XCTAssertEqual(raceBox(.connecting("RaceBox Micro")).kind, .searching)
    }

    /// The Micro has no battery, so the connected line carries a voltage.
    func testConnectedLineCarriesRateAndRail() {
        let s = raceBox(.connected, hz: 24.6, power: .supply(volts: 12.4, kind: .vehicle, isLow: false))
        XCTAssertEqual(s.kind, .connected)
        XCTAssertEqual(s.line, "Connected · 25 Hz · 12.4 V")
        XCTAssertFalse(s.attention)
    }

    func testASaggingRailAsksForAttentionWithoutLeavingConnected() {
        let s = raceBox(.connected, hz: 25, power: .supply(volts: 11.2, kind: .vehicle, isLow: true))
        XCTAssertEqual(s.kind, .connected)
        XCTAssertTrue(s.attention)
    }

    func testStalledDataStaysConnectedButSaysSo() {
        let s = raceBox(.connected, stalled: true, hz: 25)
        XCTAssertEqual(s.kind, .connected)
        XCTAssertEqual(s.sub, "No data for 5 s")
        XCTAssertTrue(s.attention)
    }

    /// The reason belongs in the log. The card says the one thing that
    /// matters, in a colour, and the controller lets it go quiet after a
    /// minute by dropping back to idle.
    func testAFreshFailureIsLoudAndWordless() {
        let s = raceBox(.failed("Peripheral not found"))
        XCTAssertEqual(s.kind, .notConnected)
        XCTAssertEqual(s.line, "Couldn’t connect")
        XCTAssertNil(s.sub)
        XCTAssertTrue(s.attention)
        XCTAssertEqual(s.dot, Color.accent)
    }

    func testBothDevicesColourAFreshFailureTheSameWay() {
        XCTAssertEqual(raceBox(.failed("x")).dot, Color.accent)
        XCTAssertEqual(obd(.notFound, freshFailure: true).dot, Color.accent)
        // ...and both go quiet once it is no longer news.
        XCTAssertEqual(raceBox(.idle).dot, Color.muted)
        XCTAssertEqual(obd(.notFound, freshFailure: false).dot, Color.muted)
    }

    /// Both devices talk over the same radio, so both say the same thing when
    /// it is off — whatever the link happened to be doing.
    func testRadioOffOutranksWhateverTheLinkWasDoing() {
        for state: RaceBoxController.State in [.idle, .scanning, .connected] {
            let s = raceBox(state, radio: .poweredOff)
            XCTAssertEqual(s.line, "Bluetooth is off", "\(state)")
        }
        XCTAssertEqual(raceBox(.idle, radio: .unauthorized).line, "Bluetooth not allowed")
    }

    func testBothDevicesWordARadioOffTheSameWay() {
        XCTAssertEqual(raceBox(.idle, radio: .poweredOff).line, obd(.bluetoothOff).line)
        XCTAssertEqual(raceBox(.idle, radio: .poweredOff).sub, obd(.bluetoothOff).sub)
    }

    /// Nothing is broken when the radio is off — it is grey, not red.
    func testARadioOffIsGreyNotRed() {
        XCTAssertEqual(obd(.bluetoothOff).dot, Color.muted)
        XCTAssertEqual(raceBox(.idle, radio: .poweredOff).dot, Color.muted)
    }

    // MARK: - OBD-II

    private func obd(_ status: OBDAdapterUIStatus,
                     radio: BluetoothRadioState = .poweredOn,
                     stored: Bool = true,
                     disconnected: Bool = false,
                     pids: Int = 0,
                     freshFailure: Bool = false) -> DeviceLinkStatus {
        .obd(status: status, radio: radio, hasStoredAdapter: stored,
             userDisconnected: disconnected, pidCount: pids,
             failureIsFresh: freshFailure)
    }

    /// The Simulator — and a Mac without BLE — reports "unsupported", not
    /// "off". Both devices should still say the same thing.
    func testBothDevicesAgreeOnEveryRadioState() {
        for radio: BluetoothRadioState in [.poweredOff, .unauthorized, .unsupported] {
            let a = raceBox(.idle, radio: radio)
            let b = obd(.finding, radio: radio)
            XCTAssertEqual(a.line, b.line, "\(radio)")
            XCTAssertEqual(a.sub, b.sub, "\(radio)")
            XCTAssertEqual(a.dot, Color.muted, "\(radio)")
            XCTAssertEqual(b.dot, Color.muted, "\(radio)")
        }
    }

    /// A radio that is off is not a failure, whatever happened before it.
    func testARadioOffIsNeverColouredByAnEarlierFailure() {
        let s = obd(.finding, radio: .unsupported, freshFailure: true)
        XCTAssertFalse(s.attention)
        XCTAssertEqual(s.dot, Color.muted)
    }

    func testARadioOffCarriesNoInstruction() {
        XCTAssertNil(obd(.bluetoothOff).sub)
        XCTAssertNil(raceBox(.idle, radio: .poweredOff).sub)
    }

    func testAStaleFailureNeverContradictsALiveLink() {
        let s = obd(.connected("VEEPEAK", waitingForIgnition: false),
                    pids: 18, freshFailure: true)
        XCTAssertEqual(s.kind, .connected)
        XCTAssertFalse(s.attention)
    }

    func testEveryInFlightStateCollapsesToSearching() {
        let adapter = DiscoveredAdapter(id: UUID(), name: "VEEPEAK", rssi: -55)
        for status: OBDAdapterUIStatus in [.finding, .connecting("VEEPEAK"),
                                           .reconnecting("VEEPEAK"), .found([adapter])] {
            XCTAssertEqual(obd(status).kind, .searching, "\(status)")
        }
    }

    func testNotFoundMeansSetupOnlyWhenNothingWasEverPaired() {
        XCTAssertEqual(obd(.notFound, stored: false).kind, .notSetUp)
        XCTAssertEqual(obd(.notFound, stored: true).kind, .notConnected)
        XCTAssertEqual(obd(.notFound, stored: true).line, "Not connected")
    }

    /// Car off is a connected adapter, not a broken one — and the page shows
    /// the instruction rather than the state.
    func testWaitingForIgnitionIsConnectedWithSomethingToDo() {
        let s = obd(.connected("VEEPEAK", waitingForIgnition: true))
        XCTAssertEqual(s.kind, .connected)
        XCTAssertEqual(s.line, "Car off")
        XCTAssertEqual(s.pill, "Turn the key to ON")
        XCTAssertTrue(s.attention)
    }

    func testLivePidsAppearOnlyOnceTheBitmapIsRead() {
        XCTAssertEqual(obd(.connected("VEEPEAK", waitingForIgnition: false), pids: 18).line,
                       "Connected · 18 PIDs")
        XCTAssertEqual(obd(.connected("VEEPEAK", waitingForIgnition: false), pids: 0).line,
                       "Connected")
    }

    // MARK: - Protocol names

    func testProtocolDigitBecomesSomethingReadable() {
        XCTAssertEqual(ObdProtocolName.short("6"), "CAN 11/500")
        XCTAssertEqual(ObdProtocolName.short("A6"), "CAN 11/500")   // "A" = auto-searched
        XCTAssertEqual(ObdProtocolName.short("3"), "ISO 9141-2")
        XCTAssertNil(ObdProtocolName.short("0"))                     // still searching
        XCTAssertNil(ObdProtocolName.short("NO DATA"))
    }
}
