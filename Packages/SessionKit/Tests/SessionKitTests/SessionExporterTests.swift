import XCTest
@testable import SessionKit
import ObdKit

final class SessionExporterTests: XCTestCase {

    private var store: SessionStore!

    override func setUp() {
        store = SessionStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }

    private func makeSession() async throws -> SessionManifest {
        var manifest = SessionManifest(
            startedAtUTC: Date(timeIntervalSince1970: 1_800_000_000), // 2027-01-15T08:00:00Z
            startUptime: 100
        )
        manifest.car = .init(make: "Mazda", model: "MX-5", vin: "JM1NDAM75K0313248")
        manifest.units = "imperial"
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: manifest.id))
        // gps.speed: 10 m/s at t=100.0, 12 m/s at t=100.2 — rpm arrives late at t=100.1
        await writer.append(.gpsSpeed, value: 10, at: 100.0)
        await writer.append(.gpsSpeed, value: 12, at: 100.2)
        await writer.append(ChannelId.obd(.rpm), value: 3000, at: 100.1)
        _ = await writer.close()
        return manifest
    }

    func testCsvGolden() async throws {
        let manifest = try await makeSession()
        let csv = SessionExporter.csv(manifest: manifest, sessionDirectory: store.directory(for: manifest.id))
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines[0], "time_s,utc,gps_speed,obd_rpm")
        XCTAssertEqual(lines.count, 4) // header + rows at 0.0, 0.1, 0.2
        // Row 1: only GPS exists yet — rpm cell is empty, not zero
        XCTAssertEqual(lines[1], "0.0,2027-01-15T08:00:00.000Z,10,")
        // Row 2: rpm appears
        XCTAssertEqual(lines[2], "0.1,2027-01-15T08:00:00.100Z,10,3000")
        // Row 3: speed updates, rpm holds last-known while still fresh
        XCTAssertEqual(lines[3], "0.2,2027-01-15T08:00:00.200Z,12,3000")
    }

    func testCsvBlanksAcrossSensorBlackout() async throws {
        let manifest = SessionManifest(
            startedAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
            startUptime: 100)
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: manifest.id))
        await writer.append(.gpsSpeed, value: 20, at: 100.0)
        await writer.append(.gpsSpeed, value: 21, at: 100.5)
        // Multi-minute blackout, then a brief resume (matches the locked-phone failure).
        await writer.append(.gpsSpeed, value: 2, at: 500.0)
        _ = await writer.close()

        let csv = SessionExporter.csv(manifest: manifest, sessionDirectory: store.directory(for: manifest.id))
        let lines = csv.split(separator: "\n").map(String.init)
        // Mid-blackout row must be blank, not frozen at 21.
        let mid = lines.first { $0.hasPrefix("200.0,") }
        XCTAssertEqual(mid, "200.0,2027-01-15T08:03:20.000Z,")
        let resume = lines.first { $0.hasPrefix("400.0,") }
        XCTAssertEqual(resume, "400.0,2027-01-15T08:06:40.000Z,2")
    }

    func testSidecarRoundtrips() async throws {
        let manifest = try await makeSession()
        let data = try SessionExporter.sidecarJson(
            manifest: manifest, sessionDirectory: store.directory(for: manifest.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded.car?.vin, "JM1NDAM75K0313248")
        XCTAssertEqual(decoded.units, "imperial")
        XCTAssertFalse(decoded.channels.isEmpty)
        XCTAssertNotNil(decoded.channels.first { $0.id == .gpsSpeed }?.measuredHz)
        XCTAssertNotNil(decoded.gForceValidation)
    }

    func testExportFilesWritten() async throws {
        let manifest = try await makeSession()
        let output = store.rootDirectory.appendingPathComponent("export")
        let files = try SessionExporter.exportFiles(
            manifest: manifest,
            sessionDirectory: store.directory(for: manifest.id),
            to: output
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.csv.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.raw.path))
        XCTAssertTrue(files.csv.lastPathComponent.hasSuffix(".csv"))
        XCTAssertTrue(files.raw.lastPathComponent.hasSuffix("-raw.json"))

        let raw = try Data(contentsOf: files.raw)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let channels = obj?["channels"] as? [String: Any]
        XCTAssertNotNil(channels?["gps.speed"])
        XCTAssertNotNil(channels?["obd.rpm"])
    }

    func testValueFormatting() {
        XCTAssertEqual(SessionExporter.format(3000), "3000")
        XCTAssertEqual(SessionExporter.format(12.345), "12.345")
        XCTAssertEqual(SessionExporter.format(34.876543219), "34.8765")
        XCTAssertEqual(SessionExporter.format(0), "0")
    }

    func testChannelStatsMeasuredHz() {
        let samples = (0..<11).map { ChannelSample(t: Double($0) * 0.1, value: Double($0)) }
        let summary = ChannelStats.enrichSummary(id: .gpsSpeed, samples: samples)
        XCTAssertEqual(summary.sampleCount, 11)
        XCTAssertEqual(summary.measuredHz ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(summary.dutyCycle ?? -1, 1.0, accuracy: 0.01) // gps expected 1 Hz → capped
        // Wait - gps expected is 1 Hz, measured is 10 Hz, duty = min(1, 10/1) = 1. Good.

        let imu = ChannelStats.enrichSummary(
            id: .imuAccelX,
            samples: (0..<101).map { ChannelSample(t: Double($0) * 0.01, value: 0) })
        XCTAssertEqual(imu.measuredHz ?? -1, 100, accuracy: 0.5)
        XCTAssertEqual(imu.dutyCycle ?? -1, 1.0, accuracy: 0.01)
    }

    func testObdTimingFromRpm() async throws {
        var manifest = SessionManifest(
            startedAtUTC: Date(timeIntervalSince1970: 1_800_000_000), startUptime: 0)
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: manifest.id))
        for i in 0..<30 {
            await writer.append(ChannelId.obd(.rpm), value: 2000, at: Double(i) / 15.0)
        }
        _ = await writer.close()
        let timing = ChannelStats.obdTiming(
            inSessionDirectory: store.directory(for: manifest.id), sessionDuration: 2)
        XCTAssertEqual(timing?.referenceChannel, "obd.rpm")
        XCTAssertEqual(timing?.measuredHz ?? -1, 15, accuracy: 0.5)
        XCTAssertNotNil(timing?.medianIntervalMs)
    }
}
