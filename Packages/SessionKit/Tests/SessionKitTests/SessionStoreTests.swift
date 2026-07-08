import XCTest
@testable import SessionKit
import ObdKit

final class SessionStoreTests: XCTestCase {

    private var store: SessionStore!

    override func setUp() {
        store = SessionStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.rootDirectory)
    }

    private func makeManifest(startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SessionManifest {
        SessionManifest(startedAtUTC: startedAt, startUptime: 100)
    }

    func testCreateListDelete() throws {
        let a = makeManifest(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let b = makeManifest(startedAt: Date(timeIntervalSince1970: 1_800_100_000))
        try store.create(a)
        try store.create(b)

        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [b.id, a.id], "newest first")

        try store.delete(a.id)
        XCTAssertEqual(store.list().map(\.id), [b.id])
    }

    func testManifestRoundtrip() throws {
        var manifest = makeManifest()
        manifest.car = .init(make: "Mazda", model: "MX-5", vin: "JM1NDAM75K0313248")
        manifest.note = "195/50R16, 32 psi cold"
        manifest.obdGaps = [.init(start: 120, end: 124.1)]
        try store.create(manifest)
        let loaded = try store.manifest(for: manifest.id)
        XCTAssertEqual(loaded, manifest)
    }

    func testRecoveryFinalizesInterruptedSession() async throws {
        // Simulate a crash: session created, samples written, never stopped
        var manifest = makeManifest()
        manifest.status = .recording
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: manifest.id))
        for i in 0..<50 {
            let t = 100.0 + Double(i)
            await writer.append(.gpsSpeed, value: 20, at: t)                 // 20 m/s steady
            await writer.append(ChannelId.obd(.rpm), value: 4000, at: t)
        }
        await writer.flushAll()
        // No close(), no stop() — the "crash"

        let recovered = store.recoverInterruptedSessions()
        XCTAssertEqual(recovered.count, 1)
        let session = recovered[0]
        XCTAssertEqual(session.status, .recovered)
        XCTAssertEqual(session.channels.first { $0.id == .gpsSpeed }?.sampleCount, 50)
        XCTAssertEqual(session.highlights?.maxRpm, 4000)
        XCTAssertEqual(session.highlights?.durationSeconds ?? 0, 49, accuracy: 0.001)
        // ~20 m/s × 49 s ≈ 980 m
        XCTAssertEqual(session.highlights?.distanceMeters ?? 0, 980, accuracy: 1)

        // Second recovery pass finds nothing — recovery is idempotent
        XCTAssertTrue(store.recoverInterruptedSessions().isEmpty)
    }

    func testStorageBytes() async throws {
        let manifest = makeManifest()
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: manifest.id))
        for i in 0..<1000 {
            await writer.append(.gpsSpeed, value: 1, at: Double(i))
        }
        _ = await writer.close()
        XCTAssertGreaterThan(store.totalStorageBytes(), 16_000) // 1000 × 16B + manifest
    }
}
