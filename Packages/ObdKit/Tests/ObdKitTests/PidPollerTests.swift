import XCTest
@testable import ObdKit

final class PidPollerTests: XCTestCase {

    /// Collect the first `count` samples, then terminate the stream.
    private func collect(_ count: Int, from poller: PidPoller) async -> [ObdSample] {
        var samples: [ObdSample] = []
        for await sample in await poller.samples() {
            samples.append(sample)
            if samples.count >= count { break }
        }
        return samples
    }

    func testMultiPidFastLoop() async throws {
        let transport = ReplayTransport(simple: [
            "010C0D111": "410C1AF80D3C1145", // RPM + speed + throttle, one round-trip
        ])
        let poller = PidPoller(
            session: Elm327Session(transport: transport),
            configuration: PollerConfiguration(slowChannels: [])
        )
        let samples = await collect(6, from: poller)

        let rpm = samples.filter { $0.channel == .rpm }
        let speed = samples.filter { $0.channel == .speed }
        let throttle = samples.filter { $0.channel == .throttle }
        XCTAssertEqual(rpm.first?.value ?? 0, 1726, accuracy: 0.001)
        XCTAssertEqual(speed.first?.value, 60)
        XCTAssertEqual(throttle.first?.value ?? 0, 27.06, accuracy: 0.01)
        XCTAssertFalse(rpm.isEmpty)
        XCTAssertFalse(speed.isEmpty)
        XCTAssertFalse(throttle.isEmpty)
    }

    func testSlowLoopInterleaved() async throws {
        let transport = ReplayTransport(simple: [
            "010C0D111": "410C1AF80D3C1145",
            "01051": "41057B", // coolant 83°C
        ])
        let poller = PidPoller(
            session: Elm327Session(transport: transport),
            configuration: PollerConfiguration(
                slowChannels: [.coolantTemp],
                slowSweepInterval: 0 // every cycle is "due" in tests
            )
        )
        let samples = await collect(8, from: poller)
        let coolant = samples.filter { $0.channel == .coolantTemp }
        XCTAssertEqual(coolant.first?.value, 83)
    }

    func testMultiPidRejectionFallsBackToSequential() async throws {
        let transport = ReplayTransport(simple: [
            "010C0D111": "NO DATA",   // ECU refuses multi-PID
            "010C1": "410C1AF8",
            "010D1": "410D3C",
            "01111": "411145",
        ])
        let poller = PidPoller(
            session: Elm327Session(transport: transport),
            configuration: PollerConfiguration(slowChannels: [])
        )
        let samples = await collect(6, from: poller)
        XCTAssertTrue(samples.contains { $0.channel == .rpm })
        XCTAssertTrue(samples.contains { $0.channel == .speed })
        XCTAssertTrue(samples.contains { $0.channel == .throttle })
        XCTAssertTrue(transport.sentCommands.contains("010C1"))
    }

    func testUnsupportedSlowChannelDroppedWithoutKillingLoop() async throws {
        let transport = ReplayTransport(simple: [
            "010C0D111": "410C1AF80D3C1145",
            "015C1": "NO DATA",  // no oil temp on this car
            "01051": "41057B",
        ])
        let poller = PidPoller(
            session: Elm327Session(transport: transport),
            configuration: PollerConfiguration(
                slowChannels: [.oilTemp, .coolantTemp],
                slowSweepInterval: 0
            )
        )
        let samples = await collect(10, from: poller)
        XCTAssertTrue(samples.contains { $0.channel == .coolantTemp })
        XCTAssertFalse(samples.contains { $0.channel == .oilTemp })
        let dropped = await poller.droppedChannels
        XCTAssertTrue(dropped.contains(.oilTemp))
    }

    func testAppliesSupportedPidFilter() async throws {
        let transport = ReplayTransport(simple: [
            "010C0D1": "410C1AF80D3C", // throttle filtered out up front
        ])
        let poller = PidPoller(
            session: Elm327Session(transport: transport),
            configuration: PollerConfiguration(slowChannels: [])
        )
        await poller.apply(supportedPids: SupportedPids(pids: [0x0C, 0x0D]))
        let samples = await collect(4, from: poller)
        XCTAssertTrue(samples.contains { $0.channel == .rpm })
        XCTAssertFalse(samples.contains { $0.channel == .throttle })
    }
}
