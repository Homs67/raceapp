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
        // Row 3: speed updates, rpm holds last-known
        XCTAssertEqual(lines[3], "0.2,2027-01-15T08:00:00.200Z,12,3000")
    }

    func testSidecarRoundtrips() async throws {
        let manifest = try await makeSession()
        let data = try SessionExporter.sidecarJson(manifest: manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded.car?.vin, "JM1NDAM75K0313248")
        XCTAssertEqual(decoded.units, "imperial")
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
        XCTAssertTrue(files.csv.lastPathComponent.hasSuffix(".csv"))
    }

    func testValueFormatting() {
        XCTAssertEqual(SessionExporter.format(3000), "3000")
        XCTAssertEqual(SessionExporter.format(12.345), "12.345")
        XCTAssertEqual(SessionExporter.format(34.876543219), "34.8765")
        XCTAssertEqual(SessionExporter.format(0), "0")
    }
}
