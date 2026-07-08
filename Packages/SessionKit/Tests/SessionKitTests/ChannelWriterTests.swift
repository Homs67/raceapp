import XCTest
@testable import SessionKit

final class ChannelWriterTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundtrip() async throws {
        let writer = try SessionWriter(sessionDirectory: directory)
        for i in 0..<100 {
            await writer.append(.gpsSpeed, value: Double(i) * 0.5, at: Double(i) * 0.1)
        }
        let counts = await writer.close()
        XCTAssertEqual(counts[.gpsSpeed], 100)

        let samples = ChannelReader.samples(for: .gpsSpeed, inSessionDirectory: directory)
        XCTAssertEqual(samples.count, 100)
        XCTAssertEqual(samples[0], ChannelSample(t: 0, value: 0))
        XCTAssertEqual(samples[99].t, 9.9, accuracy: 1e-9)
        XCTAssertEqual(samples[99].value, 49.5, accuracy: 1e-9)
    }

    func testUnflushedTailSurvivesViaFlushAll() async throws {
        // Small buffer threshold not reached — data only on disk after flush
        let writer = try SessionWriter(sessionDirectory: directory, flushEveryBytes: 1_000_000)
        await writer.append(ChannelId.obd(.rpm), value: 3000, at: 1.0)
        await writer.flushAll()
        let samples = ChannelReader.samples(for: ChannelId.obd(.rpm), inSessionDirectory: directory)
        XCTAssertEqual(samples, [ChannelSample(t: 1.0, value: 3000)])
    }

    func testMultipleChannelsSeparateFiles() async throws {
        let writer = try SessionWriter(sessionDirectory: directory)
        await writer.append(ChannelId.obd(.rpm), value: 2500, at: 1)
        await writer.append(.gpsLatitude, value: 34.87, at: 1)
        await writer.append(.imuAccelX, value: 0.4, at: 1)
        _ = await writer.close()

        let channels = ChannelReader.channels(inSessionDirectory: directory)
        XCTAssertEqual(Set(channels), [ChannelId.obd(.rpm), .gpsLatitude, .imuAccelX])
    }

    func testAppendAfterReopen() async throws {
        // Recovery scenario: writer dies, a new one appends to the same files
        let first = try SessionWriter(sessionDirectory: directory)
        await first.append(.gpsSpeed, value: 1, at: 1)
        _ = await first.close()

        let second = try SessionWriter(sessionDirectory: directory)
        await second.append(.gpsSpeed, value: 2, at: 2)
        _ = await second.close()

        let samples = ChannelReader.samples(for: .gpsSpeed, inSessionDirectory: directory)
        XCTAssertEqual(samples.map(\.value), [1, 2])
    }
}
