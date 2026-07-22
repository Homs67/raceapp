import Foundation

/// Export per R4.5: wide CSV on a fixed 10Hz master timeline with
/// short last-known-value fill (opens in Excel, imports into RaceChrono),
/// plus a JSON sidecar carrying the session metadata and channel inventory.
/// Cells go blank once a channel's sample is older than its hold age so
/// multi-minute sensor blackouts are visible instead of frozen values.
///
/// Also writes a native-rate raw dump (`*-raw.json`) for accuracy audits.
public enum SessionExporter {

    public static let timelineHz: Double = 10

    /// Column order: well-known channels first (GPS, IMU, OBD), then anything else.
    static func orderedChannels(_ channels: [ChannelId]) -> [ChannelId] {
        let preferred: [ChannelId] = [
            .gpsLatitude, .gpsLongitude, .gpsSpeed, .gpsAltitude, .gpsCourse,
            .gpsHorizontalAccuracy, .gpsVerticalAccuracy, .gpsSpeedAccuracy, .gpsWallTime,
            .carLatG, .carLongG,
            .imuAccelX, .imuAccelY, .imuAccelZ, .imuYawRate, .imuHeading,
            .baroRelativeAltitude,
        ]
        let known = preferred.filter(channels.contains)
        let rest = channels.filter { !known.contains($0) }.sorted()
        return known + rest
    }

    /// Attach rate stats, OBD timing, and G-force validation for export / finalize.
    public static func enrich(manifest: SessionManifest, sessionDirectory: URL) -> SessionManifest {
        var enriched = manifest
        enriched.channels = ChannelStats.enrichAll(inSessionDirectory: sessionDirectory)
        let duration = enriched.highlights?.durationSeconds
            ?? enriched.endedAtUTC.map { $0.timeIntervalSince(enriched.startedAtUTC) }
            ?? 0
        enriched.obdTiming = ChannelStats.obdTiming(
            inSessionDirectory: sessionDirectory, sessionDuration: duration)
        enriched.gForceValidation = GForceValidation.validate(sessionDirectory: sessionDirectory)
        return enriched
    }

    /// Render the CSV. Row cadence 10Hz from first to last sample; a cell holds
    /// the last value at-or-before its instant only while that sample is still
    /// fresh for the channel. Blank before the first sample and after a gap.
    public static func csv(manifest: SessionManifest, sessionDirectory: URL) -> String {
        let channels = orderedChannels(ChannelReader.channels(inSessionDirectory: sessionDirectory))
        let series = channels.map { ChannelReader.samples(for: $0, inSessionDirectory: sessionDirectory) }
        let holdAges = channels.map(maxHoldAge(for:))

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
                } else if t - samples[cursor].t > holdAges[index] + epsilon {
                    row.append("") // sample too old — do not freeze across blackouts
                } else {
                    row.append(format(samples[cursor].value))
                }
            }
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }

    /// How long a channel may be carried forward on the 10 Hz grid before the
    /// cell goes blank. Tuned just above each source's normal period.
    public static func maxHoldAge(for channel: ChannelId) -> TimeInterval {
        let id = channel.rawValue
        if id.hasPrefix("gps.") { return 2.5 }
        if id.hasPrefix("imu.") || id.hasPrefix("car.") { return 0.15 }
        if id.hasPrefix("baro.") { return 3.0 }
        if id.hasPrefix("device.") { return 8.0 }
        if id.hasPrefix("obd.") { return 1.5 }
        return 2.0
    }

    /// JSON sidecar = enriched manifest (rates, OBD timing, G-force audit).
    public static func sidecarJson(manifest: SessionManifest, sessionDirectory: URL) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(enrich(manifest: manifest, sessionDirectory: sessionDirectory))
    }

    /// Native-rate dump for accuracy / jitter analysis (not the 10 Hz held CSV).
    public static func rawSamplesJson(manifest: SessionManifest, sessionDirectory: URL) throws -> Data {
        struct SampleDTO: Encodable {
            let t: Double
            let v: Double
        }
        struct RawDump: Encodable {
            let sessionId: UUID
            let startedAtUTC: Date
            let startUptime: TimeInterval
            let note: String
            let channels: [String: [SampleDTO]]
        }

        var channels: [String: [SampleDTO]] = [:]
        for id in orderedChannels(ChannelReader.channels(inSessionDirectory: sessionDirectory)) {
            let samples = ChannelReader.samples(for: id, inSessionDirectory: sessionDirectory)
            channels[id.rawValue] = samples.map {
                SampleDTO(t: ($0.t * 1000).rounded() / 1000, v: $0.value)
            }
        }
        let dump = RawDump(
            sessionId: manifest.id,
            startedAtUTC: manifest.startedAtUTC,
            startUptime: manifest.startUptime,
            note: "Native sample times are monotonic uptime seconds; subtract startUptime for session-relative time_s. Not resampled.",
            channels: channels
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dump)
    }

    /// Write CSV + enriched JSON sidecar + native raw dump; returns URLs for the share sheet.
    public static func exportFiles(manifest: SessionManifest, sessionDirectory: URL,
                                   to outputDirectory: URL) throws -> (csv: URL, json: URL, raw: URL) {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let baseName = "LiveData-" + isoDayStamp(manifest.startedAtUTC)
        let csvUrl = outputDirectory.appendingPathComponent(baseName + ".csv")
        let jsonUrl = outputDirectory.appendingPathComponent(baseName + ".json")
        let rawUrl = outputDirectory.appendingPathComponent(baseName + "-raw.json")
        try csv(manifest: manifest, sessionDirectory: sessionDirectory)
            .data(using: .utf8)!.write(to: csvUrl, options: .atomic)
        try sidecarJson(manifest: manifest, sessionDirectory: sessionDirectory)
            .write(to: jsonUrl, options: .atomic)
        try rawSamplesJson(manifest: manifest, sessionDirectory: sessionDirectory)
            .write(to: rawUrl, options: .atomic)
        return (csvUrl, jsonUrl, rawUrl)
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
