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

    public struct ChannelSummary: Codable, Equatable, Sendable {
        public var id: ChannelId
        public var sampleCount: Int
        public init(id: ChannelId, sampleCount: Int) {
            self.id = id
            self.sampleCount = sampleCount
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
    public var channels: [ChannelSummary]
    public var highlights: Highlights?
    /// Mode-01 PIDs the ECU reported as supported at connect (capability record).
    public var supportedPids: [Int]?
    /// Imported video clips (stored in the session's videos/ directory).
    public var videos: [VideoAsset]?
    /// Camera-clock correction applied to all clips (seconds; user-nudged).
    public var videoSyncOffset: TimeInterval?

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
        self.channels = []
        self.supportedPids = supportedPids
    }

    /// UTC instant for a monotonic sample time.
    public func utcDate(forUptime t: TimeInterval) -> Date {
        startedAtUTC.addingTimeInterval(t - startUptime)
    }
}
