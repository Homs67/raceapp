import XCTest
@testable import ObdKit

final class ObdConnectionStateTests: XCTestCase {

    private func drive(_ start: ObdConnectionState, _ events: [ObdConnectionEvent]) -> ObdConnectionState? {
        var state: ObdConnectionState? = start
        for event in events {
            guard let current = state else { return nil }
            state = ObdConnectionReducer.reduce(current, event)
        }
        return state
    }

    func testHappyPathToLive() {
        let state = drive(.idle, [
            .startRequested, .peripheralSelected, .bleConnected,
            .gattReady, .elmReady, .ecuReady,
        ])
        XCTAssertEqual(state, .live)
    }

    func testIgnitionOffPath() {
        let state = drive(.idle, [
            .startRequested, .peripheralSelected, .bleConnected,
            .gattReady, .elmReady, .ecuUnavailable,
        ])
        XCTAssertEqual(state, .waitingForIgnition)
        // Retry while still off stays put; key turn goes live
        XCTAssertEqual(ObdConnectionReducer.reduce(.waitingForIgnition, .ecuUnavailable), .waitingForIgnition)
        XCTAssertEqual(ObdConnectionReducer.reduce(.waitingForIgnition, .ecuReady), .live)
    }

    func testLinkLostFromLiveReconnectsThroughGattDiscovery() {
        XCTAssertEqual(ObdConnectionReducer.reduce(.live, .linkLost), .reconnecting(attempt: 1))
        // Reconnect must rediscover services, not jump straight to ELM init
        XCTAssertEqual(ObdConnectionReducer.reduce(.reconnecting(attempt: 1), .bleConnected), .discoveringGatt)
    }

    func testLinkLostMidHandshakeReconnects() {
        for state: ObdConnectionState in [.connecting, .discoveringGatt, .initializingElm, .connectingEcu, .waitingForIgnition] {
            XCTAssertEqual(ObdConnectionReducer.reduce(state, .linkLost), .reconnecting(attempt: 1), "from \(state)")
        }
    }

    func testReconnectBackoffCountsAttempts() {
        XCTAssertEqual(
            ObdConnectionReducer.reduce(.reconnecting(attempt: 2), .reconnectFailed),
            .reconnecting(attempt: 3)
        )
    }

    func testReconnectDelayBacksOffAndCaps() {
        XCTAssertEqual(ObdConnectionReducer.reconnectDelay(attempt: 1), .milliseconds(500))
        XCTAssertEqual(ObdConnectionReducer.reconnectDelay(attempt: 2), .milliseconds(1000))
        XCTAssertEqual(ObdConnectionReducer.reconnectDelay(attempt: 10), .milliseconds(5000))
    }

    func testStopFromAnywhereGoesIdle() {
        for state: ObdConnectionState in [.scanning, .connecting, .live, .waitingForIgnition, .reconnecting(attempt: 3)] {
            XCTAssertEqual(ObdConnectionReducer.reduce(state, .stopRequested), .idle, "from \(state)")
        }
    }

    func testPermissionFlow() {
        XCTAssertEqual(ObdConnectionReducer.reduce(.scanning, .permissionDenied), .needsPermission)
        XCTAssertEqual(ObdConnectionReducer.reduce(.needsPermission, .permissionGranted), .scanning)
    }

    func testInvalidTransitionsReturnNil() {
        XCTAssertNil(ObdConnectionReducer.reduce(.idle, .ecuReady))
        XCTAssertNil(ObdConnectionReducer.reduce(.live, .gattReady))
        XCTAssertNil(ObdConnectionReducer.reduce(.idle, .linkLost))
        XCTAssertNil(ObdConnectionReducer.reduce(.scanning, .bleConnected))
    }
}
