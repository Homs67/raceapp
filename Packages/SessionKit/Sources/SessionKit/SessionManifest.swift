import Foundation

/// Per-session metadata, stored as `manifest.json` in the session directory.
/// Written atomically at start (status `.recording`) and finalized at stop —
/// a manifest still `.recording` on launch means an interrupted session (R1.5).
public struct SessionManifest: Codable, Equatable, Sendable, Identifiable {

    public enum Status: String, Codable, Sendable {
        case recording
        /// Open but not writing — the driver paused between runs. Still a live
        /// session: it holds its files and links and resumes into the same id.
        case paused
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

    /// One stretch of actual recording, in the same monotonic-uptime basis as
    /// sample `t`. A track day paused between runs leaves several; a drive that
    /// ran straight through leaves one. `end` is nil while the segment is open.
    public struct Segment: Codable, Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval?

        public init(start: TimeInterval, end: TimeInterval? = nil) {
            self.start = start
            self.end = end
        }

        /// Length of this segment; an open one is measured to `now` when given,
        /// and counts as zero when it is not.
        public func duration(asOf now: TimeInterval? = nil) -> TimeInterval {
            guard let finish = end ?? now else { return 0 }
            return max(0, finish - start)
        }
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
    /// The stretches this session actually recorded for. Absent on manifests
    /// written before pause existed — those ran continuously, so they read as
    /// one segment spanning the whole session (see `recordedSeconds`).
    public var segments: [Segment]?
    public var channels: [ChannelSummary]
    public var highlights: Highlights?
    /// Mode-01 PIDs the ECU reported as supported at connect (capability record).
    public var supportedPids: [Int]?
    /// Imported video clips (stored in the session's videos/ directory).
    public var videos: [VideoAsset]?
    /// Camera-clock correction applied to all clips (seconds; user-nudged).
    /// Superseded by `videoSync`; still read as the fallback for both cameras.
    public var videoSyncOffset: TimeInterval?
    /// Per-camera alignment and the review crop, set in Video sync.
    public var videoSync: VideoSync?
    /// Post-session IMU↔GPS consistency check (also recomputed on export).
    public var gForceValidation: GForceValidation?
    /// Which sensor fed the canonical `gps.*` / `car.*` channels, and when.
    ///
    /// A logger can drop out mid-session and the phone takes over, which
    /// changes the sample rate underneath every consumer — lap timing and drag
    /// runs silently get coarser. Recording the switch keeps an export honest
    /// about where each stretch of data came from, the way `obdGaps` does for
    /// the adapter. Absent on phone-only sessions.
    public var motionSourceSegments: [MotionSourceSegment]?

    public enum MotionSource: String, Codable, Sendable {
        case phone
        case raceBox
    }

    public struct MotionSourceSegment: Codable, Equatable, Sendable {
        public var source: MotionSource
        public var start: TimeInterval
        public var end: TimeInterval?

        public init(source: MotionSource, start: TimeInterval, end: TimeInterval? = nil) {
            self.source = source
            self.start = start
            self.end = end
        }
    }
    /// Effective OBD poll timing from recorded samples.
    public var obdTiming: ObdTiming?
    /// The track this session was driven on, and its runs/laps as last timed
    /// against that track's gates. Re-timed whenever the track is edited, so
    /// this is a cache of the truth (the GPS channels + the track), not the
    /// truth itself.
    public var track: TrackRef?
    /// Conditions at the session's place and time (Apple Weather, fetched
    /// after the drive). Stored so the session shows it offline and exports it.
    public var weather: WeatherSnapshot?

    public struct WeatherSnapshot: Codable, Equatable, Sendable {
        public var temperatureC: Double
        /// 0…1
        public var humidity: Double
        public var windMps: Double
        /// Meteorological: the direction the wind blows from, degrees true.
        public var windFromDegrees: Double
        /// SF Symbol for the condition, as the weather source names it.
        public var symbolName: String
        public var condition: String
        /// The hour the values describe.
        public var observedAt: Date
        public var source: String

        public init(temperatureC: Double, humidity: Double, windMps: Double, windFromDegrees: Double,
                    symbolName: String, condition: String, observedAt: Date, source: String) {
            self.temperatureC = temperatureC
            self.humidity = humidity
            self.windMps = windMps
            self.windFromDegrees = windFromDegrees
            self.symbolName = symbolName
            self.condition = condition
            self.observedAt = observedAt
            self.source = source
        }

        /// 8-point compass name of where the wind comes from ("W", "NE"…).
        public var windCompass: String {
            let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            let d = (windFromDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            return names[Int((d + 22.5) / 45) % 8]
        }
    }

    public struct TrackRef: Codable, Equatable, Sendable {
        public enum AssignedBy: String, Codable, Sendable { case auto, manual }
        public var id: String
        /// Name at assignment time — still shown if the track is deleted.
        public var nameSnapshot: String
        public var assignedBy: AssignedBy
        /// Gates the runs below were timed against (exported with the session).
        public var layout: CourseLayout?
        /// The track's `updatedAt` when these runs were computed.
        public var timedAgainst: Date?
        public var runs: [TimedRun]

        public init(id: String, nameSnapshot: String, assignedBy: AssignedBy,
                    layout: CourseLayout?, timedAgainst: Date?, runs: [TimedRun]) {
            self.id = id
            self.nameSnapshot = nameSnapshot
            self.assignedBy = assignedBy
            self.layout = layout
            self.timedAgainst = timedAgainst
            self.runs = runs
        }

        public var best: TimeInterval? { CourseTiming.best(runs) }

        /// Automatic matching may replace an automatic choice, never a manual one.
        public static func autoMatchMayReplace(_ existing: TrackRef?) -> Bool {
            existing?.assignedBy != .manual
        }
    }
    /// What the adapter was doing while CAN streaming: filter probe verdicts,
    /// the chosen mode, and a frames-per-ID tally every 30 s. This is how a
    /// drive with blank gauges gets diagnosed from its export alone.
    public var obdNotes: [ObdNote]?

    public struct ObdNote: Codable, Equatable, Sendable {
        public var t: TimeInterval
        public var text: String
        public init(t: TimeInterval, text: String) {
            self.t = t
            self.text = text
        }
    }

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

    /// Seconds this session actually recorded for, with paused time taken out.
    /// Pass `now` (monotonic uptime) to include a segment that is still open.
    ///
    /// Manifests from before pause existed carry no segments; they recorded
    /// continuously, so their finalized duration — or, while still live, the
    /// whole span since start — is already the answer.
    public func recordedSeconds(asOf now: TimeInterval? = nil) -> TimeInterval {
        guard let segments else {
            if let finalized = highlights?.durationSeconds, finalized > 0 { return finalized }
            guard let now else { return 0 }
            return max(0, now - startUptime)
        }
        return segments.reduce(0) { $0 + $1.duration(asOf: now) }
    }

    /// True while a session is open but not writing.
    public var isPaused: Bool { status == .paused }

    /// A live session is one the recorder still owns — recording or paused.
    public var isLive: Bool { status == .recording || status == .paused }
}
