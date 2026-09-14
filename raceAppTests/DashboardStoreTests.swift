import XCTest
@testable import raceApp

@MainActor
final class DashboardStoreTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dash-tests-\(UUID().uuidString)")
            .appendingPathComponent("dashboards.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testSeedsLapTimerWhenNoFile() {
        let store = DashboardStore(fileURL: url)
        XCTAssertEqual(store.dashboards.map(\.name), ["Lap Timer", "Driving"])
        XCTAssertEqual(store.selectedId, store.dashboards.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "seed is persisted immediately")
    }

    func testRoundTripsEdits() {
        let store = DashboardStore(fileURL: url)
        var d = store.dashboards[0]
        d.name = "Race day"
        d.placements.append(WidgetPlacement(kind: .lapTime, size: .small, settings: ["reference": "session"]))
        store.update(d)
        let reloaded = DashboardStore(fileURL: url)
        XCTAssertEqual(reloaded.dashboards[0].name, "Race day")
        XCTAssertEqual(reloaded.dashboards[0].placements.count, 6)
        XCTAssertEqual(reloaded.dashboards[0].placements.last?.settings["reference"], "session")
    }

    func testUnknownWidgetKindIsDroppedNotFatal() throws {
        let store = DashboardStore(fileURL: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"kind\" : \"bestLap\"", with: "\"kind\" : \"hologram\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let reloaded = DashboardStore(fileURL: url)
        XCTAssertEqual(reloaded.dashboards[0].placements.count, store.dashboards[0].placements.count - 1)
        XCTAssertFalse(reloaded.dashboards[0].placements.contains { $0.kind == .unknown })
    }

    func testCorruptFileReseeds() throws {
        _ = DashboardStore(fileURL: url)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let store = DashboardStore(fileURL: url)
        XCTAssertEqual(store.dashboards.map(\.name), ["Lap Timer", "Driving"])
    }

    func testAddRejectsOverflowAndCap() {
        let store = DashboardStore(fileURL: url)
        let tooBig = Dashboard(name: "Big", placements: (0..<5).map { _ in WidgetPlacement(kind: .lapTime, size: .medium) })
        XCTAssertFalse(store.add(tooBig))
        for i in 0..<10 { _ = store.add(Dashboard(name: "D\(i)", placements: [WidgetPlacement(kind: .lastLap, size: .small)])) }
        XCTAssertEqual(store.dashboards.count, Dashboard.maxCount)
    }

    func testRemoveLastReseedsAndLegacyKeyIsCleared() {
        UserDefaults.standard.set(3, forKey: "dashboardFace")
        let store = DashboardStore(fileURL: url)
        XCTAssertNil(UserDefaults.standard.object(forKey: "dashboardFace"))
        store.remove(id: store.dashboards[0].id)
        store.remove(id: store.dashboards[0].id)
        XCTAssertEqual(store.dashboards.count, 2, "removing the last dashboard reseeds")
        XCTAssertEqual(store.selectedId, store.dashboards[0].id)
    }

    func testDuplicateGetsFreshIds() {
        let store = DashboardStore(fileURL: url)
        let source = store.dashboards[0]
        let copy = store.duplicate(id: source.id)!
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(Set(copy.placements.map(\.id)).intersection(source.placements.map(\.id)).count, 0)
        XCTAssertEqual(store.dashboards.count, 3)
    }
}
