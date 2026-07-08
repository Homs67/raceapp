import XCTest
@testable import ObdKit

final class Elm327SessionTests: XCTestCase {

    private func makeSession(_ responses: [String: String]) -> (Elm327Session, ReplayTransport) {
        let transport = ReplayTransport(simple: responses)
        return (Elm327Session(transport: transport), transport)
    }

    private static let initResponses: [String: String] = [
        "ATZ": "ATZ\rELM327 v2.2",   // ATZ echoes (echo still on at reset)
        "ATE0": "OK",
        "ATL0": "OK",
        "ATS0": "OK",
        "ATH0": "OK",
        "ATSP0": "OK",
        "ATSP6": "OK",
        "ATAT2": "OK",
    ]

    func testInitSequence() async throws {
        let (session, transport) = makeSession(Self.initResponses)
        let info = try await session.initialize()
        XCTAssertEqual(info.version, "ELM327 v2.2")
        XCTAssertEqual(transport.sentCommands, ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0", "ATAT2"])
    }

    func testInitPinsPersistedProtocol() async throws {
        let (session, transport) = makeSession(Self.initResponses)
        _ = try await session.initialize(elmProtocol: 6)
        XCTAssertTrue(transport.sentCommands.contains("ATSP6"))
        XCTAssertFalse(transport.sentCommands.contains("ATSP0"))
    }

    func testChunkedResponseAssembly() async throws {
        // chunkSize 1: every byte arrives as its own BLE notification
        let transport = ReplayTransport(simple: ["010C": "410C1AF8"], chunkSize: 1)
        let session = Elm327Session(transport: transport)
        let lines = try await session.execute("010C")
        XCTAssertEqual(lines, ["410C1AF8"])
    }

    func testSearchingLineSkipped() async throws {
        let (session, _) = makeSession(["0100": "SEARCHING...\r4100BE3EA813"])
        let lines = try await session.execute("0100")
        XCTAssertEqual(lines, ["4100BE3EA813"])
    }

    func testNoDataThrows() async throws {
        let (session, _) = makeSession(["015C": "NO DATA"])
        do {
            _ = try await session.execute("015C")
            XCTFail("expected ElmError.noData")
        } catch let error as ElmError {
            XCTAssertEqual(error, .noData)
        }
    }

    func testUnableToConnectThrows() async throws {
        let (session, _) = makeSession(["0100": "UNABLE TO CONNECT"])
        do {
            _ = try await session.execute("0100")
            XCTFail("expected ElmError.unableToConnect")
        } catch let error as ElmError {
            XCTAssertEqual(error, .unableToConnect)
        }
    }

    func testUnknownCommandThrows() async throws {
        let (session, _) = makeSession([:]) // replay answers "?" to anything unknown
        do {
            _ = try await session.execute("ATXX")
            XCTFail("expected ElmError.unknownCommand")
        } catch let error as ElmError {
            XCTAssertEqual(error, .unknownCommand)
        }
    }

    func testTimeoutWhenAdapterSilent() async throws {
        // A transport that never responds
        final class SilentTransport: ObdTransport, @unchecked Sendable {
            let incoming = AsyncStream<Data> { _ in }
            func send(_ data: Data) async throws {}
        }
        let session = Elm327Session(transport: SilentTransport())
        do {
            _ = try await session.execute("010C", timeout: .milliseconds(50))
            XCTFail("expected ElmError.timeout")
        } catch let error as ElmError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testConnectEcuSweepsSupportedPids() async throws {
        var responses = Self.initResponses
        // Base bitmap: 0xBE1FA813 → includes PID 0x20 marker (0x13 has bit 0 set)
        responses["0100"] = "4100BE1FA813"
        responses["0120"] = "4120A0000000" // hmm: 0xA0 → PIDs 21, 23
        let (session, _) = makeSession(responses)
        let supported = try await session.connectEcu()
        XCTAssertTrue(supported.supports(0x0C))
        XCTAssertTrue(supported.supports(0x0D))
        XCTAssertTrue(supported.supports(0x21))
        XCTAssertFalse(supported.supports(0x5C))
    }

    func testConnectEcuIgnitionOffThrows() async throws {
        var responses = Self.initResponses
        responses["0100"] = "UNABLE TO CONNECT"
        let (session, _) = makeSession(responses)
        do {
            _ = try await session.connectEcu()
            XCTFail("expected ElmError.unableToConnect")
        } catch let error as ElmError {
            XCTAssertEqual(error, .unableToConnect)
        }
    }

    func testIgnitionTurnsOnBetweenAttempts() async throws {
        // First 0100 fails (ignition off), second succeeds — WaitingForIgnition retry
        let transport = ReplayTransport(responses: [
            "0100": ["UNABLE TO CONNECT", "4100BE1EA810"], // no 0x20-range marker
        ])
        let session = Elm327Session(transport: transport)
        do {
            _ = try await session.connectEcu()
            XCTFail("first attempt should fail")
        } catch let error as ElmError {
            XCTAssertEqual(error, .unableToConnect)
        }
        let supported = try await session.connectEcu()
        XCTAssertTrue(supported.supports(0x0C))
    }

    func testReadVin() async throws {
        let transport = ReplayTransport(simple: [
            "0902": "014\r0:490201314731\r1:4A433534343452\r2:37323532333637",
        ])
        let session = Elm327Session(transport: transport)
        let vin = try await session.readVin()
        XCTAssertEqual(vin, "1G1JC5444R7252367")
    }
}
