import Foundation

/// Export per R4.5: wide CSV on a fixed 10Hz master timeline with
/// last-known-value fill (opens in Excel, imports into RaceChrono), plus a
/// JSON sidecar carrying the session metadata and channel inventory.
public enum SessionExporter {

    public static let timelineHz: Double = 10

    /// Column order: well-known channels first (GPS, IMU, OBD), then anything else.
    static func orderedChannels(_ channels: [ChannelId]) -> [ChannelId] {
        let preferred: [ChannelId] = [
            .gpsLatitude, .gpsLongitude, .gpsSpeed, .gpsAltitude, .gpsCourse, .gpsHorizontalAccuracy,
            .carLatG, .carLongG,
            .imuAccelX, .imuAccelY, .imuAccelZ, .imuYawRate, .imuHeading,
            .baroRelativeAltitude,
        ]
        let known = preferred.filter(channels.contains)
        let rest = channels.filter { !known.contains($0) }.sorted()
        return known + rest
    }

    /// Render the CSV. Row cadence 10Hz from first to last sample; a cell holds
    /// the last value at-or-before its instant (blank until a channel's first
    /// sample) — honest about when data actually existed.
    public static func csv(manifest: SessionManifest, sessionDirectory: URL) -> String {
        let channels = orderedChannels(ChannelReader.channels(inSessionDirectory: sessionDirectory))
        let series = channels.map { ChannelReader.samples(for: $0, inSessionDirectory: sessionDirectory) }

        var header = ["time_s", "utc"]
        header += channels.map { $0.rawValue.replacingOccurrences(of: ".", with: "_") }
        var out = header.joined(separator: ",") + "\n"

        let allT = series.flatMap { $0.map(\.t) }
        guard let firstT = allT.min(), let lastT = allT.max() else { return out }

        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var cursors = [Int](repeating: 0, count: series.count)
        let step = 1.0 / timelineHz
        let epsilon = 1e-6 // sample times vs. grid times never compare exactly
        let rowCount = Int(((lastT - firstT) / step + epsilon).rounded(.down)) + 1
        for rowIndex in 0..<rowCount {
            let t = firstT + Double(rowIndex) * step
            var row = [
                String(format: "%.1f", t - manifest.startUptime),
                utcFormatter.string(from: manifest.utcDate(forUptime: t)),
            ]
            for (index, samples) in series.enumerated() {
                var cursor = cursors[index]
                while cursor + 1 < samples.count, samples[cursor + 1].t <= t + epsilon { cursor += 1 }
                cursors[index] = cursor
                if samples.isEmpty || samples[cursor].t > t + epsilon {
                    row.append("") // channel hasn't produced data yet
                } else {
                    row.append(format(samples[cursor].value))
                }
            }
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }

    /// JSON sidecar = the manifest itself (car, VIN, adapter, app version,
    /// units, channel inventory, gaps, highlights) — already Codable.
    public static func sidecarJson(manifest: SessionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// Write both files to a temp directory; returns URLs for the share sheet.
    public static func exportFiles(manifest: SessionManifest, sessionDirectory: URL,
                                   to outputDirectory: URL) throws -> (csv: URL, json: URL) {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let baseName = "LiveData-" + isoDayStamp(manifest.startedAtUTC)
        let csvUrl = outputDirectory.appendingPathComponent(baseName + ".csv")
        let jsonUrl = outputDirectory.appendingPathComponent(baseName + ".json")
        try csv(manifest: manifest, sessionDirectory: sessionDirectory)
            .data(using: .utf8)!.write(to: csvUrl, options: .atomic)
        try sidecarJson(manifest: manifest).write(to: jsonUrl, options: .atomic)
        return (csvUrl, jsonUrl)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.6g", value)
    }

    private static func isoDayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
