import Foundation

/// Append-only binary channel files: 16 bytes per sample
/// (Float64 LE monotonic-uptime t, Float64 LE value), one file per channel.
/// Samples hit the buffer immediately and disk within `flushEveryBytes` or an
/// explicit `flush()` — a crash loses at most the unflushed tail (R1.5).
public actor SessionWriter {

    public static let channelsSubdirectory = "channels"
    public static let fileExtension = "f64"
    private static let recordSize = 16

    private let channelsDirectory: URL
    private var handles: [ChannelId: FileHandle] = [:]
    private var buffers: [ChannelId: Data] = [:]
    private var counts: [ChannelId: Int] = [:]
    private let flushEveryBytes: Int

    public init(sessionDirectory: URL, flushEveryBytes: Int = 4096) throws {
        self.channelsDirectory = sessionDirectory.appendingPathComponent(Self.channelsSubdirectory)
        self.flushEveryBytes = flushEveryBytes
        try FileManager.default.createDirectory(at: channelsDirectory, withIntermediateDirectories: true)
    }

    public func append(_ channel: ChannelId, value: Double, at t: TimeInterval) {
        var record = Data(capacity: Self.recordSize)
        withUnsafeBytes(of: t.bitPattern.littleEndian) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: value.bitPattern.littleEndian) { record.append(contentsOf: $0) }
        buffers[channel, default: Data()].append(record)
        counts[channel, default: 0] += 1
        if buffers[channel]!.count >= flushEveryBytes {
            try? flush(channel)
        }
    }

    public func flushAll() {
        for channel in buffers.keys where !(buffers[channel]?.isEmpty ?? true) {
            try? flush(channel)
        }
    }

    /// Flush everything and close file handles. Returns per-channel sample counts.
    public func close() -> [ChannelId: Int] {
        flushAll()
        for handle in handles.values {
            try? handle.close()
        }
        handles = [:]
        return counts
    }

    public var sampleCounts: [ChannelId: Int] { counts }

    private func flush(_ channel: ChannelId) throws {
        guard let data = buffers[channel], !data.isEmpty else { return }
        let handle = try self.handle(for: channel)
        try handle.write(contentsOf: data)
        buffers[channel] = Data()
    }

    private func handle(for channel: ChannelId) throws -> FileHandle {
        if let existing = handles[channel] { return existing }
        let url = Self.fileUrl(for: channel, in: channelsDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handles[channel] = handle
        return handle
    }

    static func fileUrl(for channel: ChannelId, in channelsDirectory: URL) -> URL {
        channelsDirectory
            .appendingPathComponent(channel.rawValue)
            .appendingPathExtension(fileExtension)
    }
}

/// Read side — used by export, recovery, and session detail.
public enum ChannelReader {

    /// All channels present in a session directory.
    public static func channels(inSessionDirectory directory: URL) -> [ChannelId] {
        let channelsDir = directory.appendingPathComponent(SessionWriter.channelsSubdirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: channelsDir.path)) ?? []
        return files
            .filter { $0.hasSuffix("." + SessionWriter.fileExtension) }
            .map { ChannelId(String($0.dropLast(SessionWriter.fileExtension.count + 1))) }
            .sorted()
    }

    public static func samples(for channel: ChannelId, inSessionDirectory directory: URL) -> [ChannelSample] {
        let channelsDir = directory.appendingPathComponent(SessionWriter.channelsSubdirectory)
        let url = SessionWriter.fileUrl(for: channel, in: channelsDir)
        guard let data = try? Data(contentsOf: url) else { return [] }
        var samples: [ChannelSample] = []
        samples.reserveCapacity(data.count / 16)
        var offset = 0
        while offset + 16 <= data.count {
            let t = Double(bitPattern: UInt64(littleEndian: data.load(at: offset)))
            let value = Double(bitPattern: UInt64(littleEndian: data.load(at: offset + 8)))
            samples.append(ChannelSample(t: t, value: value))
            offset += 16
        }
        return samples
    }

    public static func sampleCount(for channel: ChannelId, inSessionDirectory directory: URL) -> Int {
        let channelsDir = directory.appendingPathComponent(SessionWriter.channelsSubdirectory)
        let url = SessionWriter.fileUrl(for: channel, in: channelsDir)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return (size ?? 0) / 16
    }
}

private extension Data {
    func load(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest, from: offset..<(offset + 8))
        }
        return value
    }
}
