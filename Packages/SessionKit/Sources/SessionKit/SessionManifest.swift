import Foundation

/// Per-session metadata, stored as `manifest.json` in the session directory.
/// Written atomically at start (status `.recording`) and finalized at stop —
/// a manifest still `.recording` on launch means an interrupted session (R1.5).
public struct SessionManifest: Codable, Equatable, Sendable, Identifiable {

    public enum Status: String, Codable, Sendable {
        case recording
        case complete
        case recovered
    }

    public struct CarInfo: Codable, Equatable, Sendable {
        public var make: String?
        public var model: String?
        public var vin: String?
        public var adapterName: String?
        public var elmProtocol: Int?

        public init(make: String? = nil, model: String? = nil, vin: String? = nil,
                    adapterName: String? = nil, elmProtocol: Int? = nil) {
            self.make = make
            self.model = model
            self.vin = vin
            self.adapterName = adapterName
            self.elmProtocol = elmProtocol
        }
    }

    /// One OBD-link dropout while recording (R1.8) — monotonic uptime bounds.
    public struct Gap: Codable, Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
        public var duration: TimeInterval { end - start }
    }

    /// A suspension-sized interruption in one of the phone sensor sources.
    public struct SensorGap: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable {
            case gps
            case motion
            case barometer
            case deviceHealth
        }

        public var source: Source
        public var start: TimeInterval
        public var end: TimeInterval

        public init(source: Source, start: TimeInterval, end: TimeInterval) {
            self.source = source
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { end - start }
    }

    public struct ChannelSummary: Codable, Equatable, Sendable {
        public var id: ChannelId
        public var sampleCount: Int
        /// (n−1) / span from first→last sample timestamp.
        public var measuredHz: Double?
        /// measuredHz / expectedHz when a nominal rate is known (capped at 1).
        public var dutyCycle: Double?
        /// Last sample t − first sample t.
        public var spanSeconds: Double?
        /// Median Δt between consecutive samples, milliseconds.
        public var medianIntervalMs: Double?

        public init(id: ChannelId, sampleCount: Int,
                    measuredHz: Double? = nil, dutyCycle: Double? = nil,
                    spanSeconds: Double? = nil, medianIntervalMs: Double? = nil) {
            self.id = id
            self.sampleCount = sampleCount
            self.measuredHz = measuredHz
            self.dutyCycle = dutyCycle
            self.spanSeconds = spanSeconds
            self.medianIntervalMs = medianIntervalMs
        }
    }

    /// OBD fast-loop timing derived from recorded `obd.rpm` (or speed) samples.
    public struct ObdTiming: Codable, Equatable, Sendable {
        public var referenceChannel: String
        public var sampleCount: Int
        public var measuredHz: Double?
        public var medianIntervalMs: Double?
        public var spanSeconds: Double?
        /// Fraction of session duration covered by OBD samples.
        public var coverage: Double?

        public init(referenceChannel: String, sampleCount: Int,
                    measuredHz: Double? = nil, medianIntervalMs: Double? = nil,
                    spanSeconds: Double? = nil, coverage: Double? = nil) {
            self.referenceChannel = referenceChannel
            self.sampleCount = sampleCount
            self.measuredHz = measuredHz
            self.medianIntervalMs = medianIntervalMs
            self.spanSeconds = spanSeconds
            self.coverage = coverage
        }
    }

    /// Session-detail highlight numbers (R4.2). SI units throughout;
    /// presentation converts per the global units setting.
    public struct Highlights: Codable, Equatable, Sendable {
        public var durationSeconds: TimeInterval = 0
        public var distanceMeters: Double = 0
        public var maxSpeedMps: Double = 0
        public var avgSpeedMps: Double = 0
        public var maxRpm: Double = 0
        public var peakLatG: Double = 0
        public var peakLongG: Double = 0
        public var elevationGainMeters: Double = 0
        public var coolantMinC: Double?
        public var coolantMaxC: Double?
        public init() {}
    }

    public var id: UUID
    public var startedAtUTC: Date
    /// Monotonic uptime at start — anchors every sample `t` to UTC.
    public var startUptime: TimeInterval
    public var status: Status
    public var endedAtUTC: Date?
    public var appVersion: String?
    public var units: String?
    public var car: CarInfo?
    public var phoneOnly: Bool
    public var note: String?
    public var locationName: String?
    public var obdGaps: [Gap]
    /// Optional for backward-compatible decoding of manifests from older builds.
    public var sensorGaps: [SensorGap]?
    public var channels: [ChannelSummary]
    public var highlights: Highlights?
    /// Mode-01 PIDs the ECU reported as supported at connect (capability record).
    public var supportedPids: [Int]?
    /// Imported video clips (stored in the session's videos/ directory).
    public var videos: [VideoAsset]?
    /// Camera-clock correction applied to all clips (seconds; user-nudged).
    public var videoSyncOffset: TimeInterval?
    /// Post-session IMU↔GPS consistency check (also recomputed on export).
    public var gForceValidation: GForceValidation?
    /// Effective OBD poll timing from recorded samples.
    public var obdTiming: ObdTiming?

    public init(id: UUID = UUID(), startedAtUTC: Date, startUptime: TimeInterval,
                status: Status = .recording, appVersion: String? = nil, units: String? = nil,
                car: CarInfo? = nil, phoneOnly: Bool = false, supportedPids: [Int]? = nil) {
        self.id = id
        self.startedAtUTC = startedAtUTC
        self.startUptime = startUptime
        self.status = status
        self.appVersion = appVersion
        self.units = units
        self.car = car
        self.phoneOnly = phoneOnly
        self.obdGaps = []
        self.sensorGaps = []
        self.channels = []
        self.supportedPids = supportedPids
    }

    /// UTC instant for a monotonic sample time.
    public func utcDate(forUptime t: TimeInterval) -> Date {
        startedAtUTC.addingTimeInterval(t - startUptime)
    }
}
