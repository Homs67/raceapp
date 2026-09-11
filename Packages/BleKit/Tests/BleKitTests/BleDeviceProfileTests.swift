import XCTest
@testable import BleKit

final class BleDeviceProfileTests: XCTestCase {

    /// Two `CBCentralManager`s sharing a restore identifier corrupts
    /// CoreBluetooth until the app relaunches — the bug that made every OBD
    /// reconnect fail. Distinct profiles must never collide.
    func testRestoreIdentifiersAreUniquePerProfile() {
        let identifiers = [BleDeviceProfile.elm327, .raceBox].compactMap(\.restoreIdentifier)
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(Set(identifiers).count, 2, "each profile needs its own restore identifier")
    }

    func testElm327ProfileAllowsCloneFallback() {
        // Adapter clones expose varying vendor UARTs, so an unknown GATT tree
        // still has to yield a usable (write, notify) pair.
        XCTAssertTrue(BleDeviceProfile.elm327.allowsHeuristicFallback)
        XCTAssertEqual(BleDeviceProfile.elm327.advertisedName, "VEEPEAK")
        XCTAssertTrue(BleDeviceProfile.elm327.serviceUUIDs.contains("FFF0"))
    }

    func testRaceBoxProfileIsExactMatchOnly() {
        // The RaceBox service is documented and fixed; falling back to "any
        // serial-looking pair" would happily attach to an unrelated device.
        let profile = BleDeviceProfile.raceBox
        XCTAssertFalse(profile.allowsHeuristicFallback)
        XCTAssertEqual(profile.advertisedName, "RaceBox")
        XCTAssertEqual(profile.serviceUUIDs, ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"])
        XCTAssertEqual(profile.writeUUIDs, ["6E400002-B5A3-F393-E0A9-E50E24DCCA9E"])
        XCTAssertEqual(profile.notifyUUIDs, ["6E400003-B5A3-F393-E0A9-E50E24DCCA9E"])
    }

    func testDeviceInfoCharacteristicsCoverTheStandardService() {
        XCTAssertEqual(DeviceInfoCharacteristic.serviceUUID, "180A")
        XCTAssertEqual(DeviceInfoCharacteristic.model.rawValue, "2A24")
        XCTAssertEqual(DeviceInfoCharacteristic.firmwareRevision.rawValue, "2A26")
        XCTAssertEqual(Set(DeviceInfoCharacteristic.allCases.map(\.rawValue)).count,
                       DeviceInfoCharacteristic.allCases.count)
    }
}

final class ReplayTransportTests: XCTestCase {

    func testStickyLastResponseRepeats() async throws {
        let transport = ReplayTransport(responses: ["AT": ["first", "second"]])
        var received: [String] = []
        let collector = Task {
            var out: [String] = []
            for await chunk in transport.incoming {
                out.append(String(data: chunk, encoding: .ascii) ?? "")
                if out.joined().contains("second\r>second\r>") { break }
            }
            return out.joined()
        }
        for _ in 0..<3 { try await transport.send(Data("AT\r".utf8)) }
        received = [await collector.value]

        // Queue drains to one entry, which then repeats for later sends.
        XCTAssertEqual(received.joined(), "first\r>second\r>second\r>")
        XCTAssertEqual(transport.sentCommands, ["AT", "AT", "AT"])
    }

    func testUnknownCommandAnswersLikeAnElm() async throws {
        let transport = ReplayTransport(simple: [:])
        let collector = Task {
            for await chunk in transport.incoming {
                return String(data: chunk, encoding: .ascii) ?? ""
            }
            return ""
        }
        try await transport.send(Data("NOPE\r".utf8))
        let reply = await collector.value
        XCTAssertTrue(reply.hasPrefix("?"), "ELM answers unknown commands with '?'")
    }
}
