import Foundation

/// Directory-per-session store. No database — the manifest JSON files are the
/// index, which keeps recovery trivial and the store crash-safe by construction.
///
/// Layout: `<root>/sessions/<uuid>/manifest.json` + `channels/*.f64`
public struct SessionStore: Sendable {

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Default store under Application Support.
    public static func standard() -> SessionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(rootDirectory: base.appendingPathComponent("LiveData", isDirectory: true))
    }

    private var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public func directory(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestUrl(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("manifest.json")
    }

    // MARK: - CRUD

    /// Create the session directory and write the initial `.recording` manifest.
    public func create(_ manifest: SessionManifest) throws {
        try FileManager.default.createDirectory(at: directory(for: manifest.id), withIntermediateDirectories: true)
        try save(manifest)
    }

    /// Atomic manifest write (temp file + rename, via `.atomic`).
    public func save(_ manifest: SessionManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestUrl(for: manifest.id), options: .atomic)
    }

    public func manifest(for id: UUID) throws -> SessionManifest {
        let data = try Data(contentsOf: manifestUrl(for: id))
        return try Self.decoder.decode(SessionManifest.self, from: data)
    }

    /// All sessions, newest first. Unreadable manifests are skipped, not fatal.
    public func list() -> [SessionManifest] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return ids
            .compactMap { UUID(uuidString: $0) }
            .compactMap { try? manifest(for: $0) }
            .sorted { $0.startedAtUTC > $1.startedAtUTC }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Total bytes used by all sessions (Connection tab storage row, R5.3).
    public func totalStorageBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 ?? 0)
        }
        return total
    }

    // MARK: - Crash recovery (R1.5)

    /// Find sessions still marked `.recording` (app died mid-session), finalize
    /// them from what reached disk, and mark them `.recovered`. Run at launch.
    @discardableResult
    public func recoverInterruptedSessions() -> [SessionManifest] {
        var recovered: [SessionManifest] = []
        for var manifest in list() where manifest.status == .recording {
            let dir = directory(for: manifest.id)
            var lastSampleT = manifest.startUptime
            var summaries: [SessionManifest.ChannelSummary] = []
            var accumulator = HighlightsAccumulator()
            for channel in ChannelReader.channels(inSessionDirectory: dir) {
                let samples = ChannelReader.samples(for: channel, inSessionDirectory: dir)
                summaries.append(.init(id: channel, sampleCount: samples.count))
                for sample in samples {
                    accumulator.add(channel: channel, value: sample.value, t: sample.t)
                }
                if let last = samples.last?.t { lastSampleT = max(lastSampleT, last) }
            }
            manifest.channels = summaries
            manifest.highlights = accumulator.finalize(startUptime: manifest.startUptime, endUptime: lastSampleT)
            manifest.endedAtUTC = manifest.utcDate(forUptime: lastSampleT)
            manifest.status = .recovered
            try? save(manifest)
            recovered.append(manifest)
        }
        return recovered
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
