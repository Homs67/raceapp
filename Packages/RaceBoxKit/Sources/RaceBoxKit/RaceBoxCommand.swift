import Foundation

// MARK: - Typed responses

/// Reply to `0xFF 0x22` — standalone recording status (Mini S / Micro).
public struct RaceBoxRecordingStatus: Equatable, Sendable {
    public let isRecording: Bool
    public let memoryLevelPercent: Int      // 0 = empty, 100 = full
    public let securityEnabled: Bool
    public let memoryUnlocked: Bool
    public let storedMessages: UInt32
    public let memorySizeMessages: UInt32

    public init?(payload: [UInt8]) {
        guard payload.count >= 12 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(payload[o]) | UInt32(payload[o + 1]) << 8
                | UInt32(payload[o + 2]) << 16 | UInt32(payload[o + 3]) << 24
        }
        isRecording = payload[0] != 0
        memoryLevelPercent = Int(payload[1])
        securityEnabled = (payload[2] & 0x01) != 0
        memoryUnlocked = (payload[2] & 0x02) != 0
        storedMessages = u32(4)
        memorySizeMessages = u32(8)
    }

    /// Estimated recording time left, given the configured rate.
    public func remainingSeconds(at rate: RaceBoxDataRate) -> Double? {
        guard rate.hz > 0, memorySizeMessages > storedMessages else { return nil }
        return Double(memorySizeMessages - storedMessages) / rate.hz
    }
}

public enum RaceBoxDataRate: UInt8, CaseIterable, Sendable {
    case hz25 = 0
    case hz10 = 1
    case hz5 = 2
    case hz1 = 3
    case hz20 = 4   // firmware 3.3+

    public var hz: Double {
        switch self {
        case .hz25: return 25
        case .hz10: return 10
        case .hz5: return 5
        case .hz1: return 1
        case .hz20: return 20
        }
    }
}

/// Filters and features bitmask shared by the recording config and state messages.
public struct RaceBoxRecordingFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let waitForFix = RaceBoxRecordingFlags(rawValue: 1 << 0)
    public static let stationaryFilter = RaceBoxRecordingFlags(rawValue: 1 << 1)
    public static let noFixFilter = RaceBoxRecordingFlags(rawValue: 1 << 2)
    public static let autoShutdown = RaceBoxRecordingFlags(rawValue: 1 << 3)
    public static let waitForDataBeforeShutdown = RaceBoxRecordingFlags(rawValue: 1 << 4)
}

/// Standalone recording configuration (`0xFF 0x25` write / read reply).
public struct RaceBoxRecordingConfig: Equatable, Sendable {
    public var enabled: Bool
    public var dataRate: RaceBoxDataRate
    public var flags: RaceBoxRecordingFlags
    public var stationaryThresholdMmps: UInt16
    public var stationaryIntervalSeconds: UInt16
    public var noFixIntervalSeconds: UInt16
    public var autoShutdownIntervalSeconds: UInt16

    public init(enabled: Bool, dataRate: RaceBoxDataRate = .hz25,
                flags: RaceBoxRecordingFlags = [],
                stationaryThresholdMmps: UInt16 = 1389,
                stationaryIntervalSeconds: UInt16 = 30,
                noFixIntervalSeconds: UInt16 = 30,
                autoShutdownIntervalSeconds: UInt16 = 300) {
        self.enabled = enabled
        self.dataRate = dataRate
        self.flags = flags
        self.stationaryThresholdMmps = stationaryThresholdMmps
        self.stationaryIntervalSeconds = stationaryIntervalSeconds
        self.noFixIntervalSeconds = noFixIntervalSeconds
        self.autoShutdownIntervalSeconds = autoShutdownIntervalSeconds
    }

    /// The doc's recommended general-purpose setup: every filter on, stop after
    /// 30 s below ~5 kph, stop after 30 s without a fix, power off after 5 min.
    public static let recommended = RaceBoxRecordingConfig(
        enabled: true, dataRate: .hz25,
        flags: [.waitForFix, .stationaryFilter, .noFixFilter,
                .autoShutdown, .waitForDataBeforeShutdown],
        stationaryThresholdMmps: 1389, stationaryIntervalSeconds: 30,
        noFixIntervalSeconds: 30, autoShutdownIntervalSeconds: 300)

    /// Same, minus the stationary filter — required to capture standing starts
    /// (drag runs), which the stationary filter would otherwise trim away.
    public static let standingStarts = RaceBoxRecordingConfig(
        enabled: true, dataRate: .hz25,
        flags: [.waitForFix, .noFixFilter, .autoShutdown, .waitForDataBeforeShutdown],
        stationaryThresholdMmps: 1389, stationaryIntervalSeconds: 30,
        noFixIntervalSeconds: 30, autoShutdownIntervalSeconds: 300)

    /// 12-byte payload: enable, rate, flags, reserved, then four UInt16s.
    public var payload: [UInt8] {
        var bytes: [UInt8] = [enabled ? 1 : 0, dataRate.rawValue, flags.rawValue, 0]
        for value in [stationaryThresholdMmps, stationaryIntervalSeconds,
                      noFixIntervalSeconds, autoShutdownIntervalSeconds] {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
        }
        return bytes
    }

    public init?(payload: [UInt8]) {
        guard payload.count >= 12 else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(payload[o]) | UInt16(payload[o + 1]) << 8 }
        enabled = payload[0] != 0
        dataRate = RaceBoxDataRate(rawValue: payload[1]) ?? .hz25
        flags = RaceBoxRecordingFlags(rawValue: payload[2])
        stationaryThresholdMmps = u16(4)
        stationaryIntervalSeconds = u16(6)
        noFixIntervalSeconds = u16(8)
        autoShutdownIntervalSeconds = u16(10)
    }
}

/// `0xFF 0x26` — recording started/stopped/paused. Saved in memory too, so a
/// download can be split back into separate drives on these boundaries.
///
/// Note the payload layout differs from the config message: state and rate sit
/// at offsets 0 and 2, with flags at 3.
public struct RaceBoxRecordingStateChange: Equatable, Sendable {
    public enum State: UInt8, Sendable {
        case disabled = 0
        case running = 1
        case paused = 2
    }

    public let state: State
    public let dataRate: RaceBoxDataRate
    public let flags: RaceBoxRecordingFlags
    public let stationaryThresholdMmps: UInt16
    public let stationaryIntervalSeconds: UInt16
    public let noFixIntervalSeconds: UInt16
    public let autoShutdownIntervalSeconds: UInt16

    public init?(payload: [UInt8]) {
        guard payload.count >= 12, let state = State(rawValue: payload[0]) else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(payload[o]) | UInt16(payload[o + 1]) << 8 }
        self.state = state
        dataRate = RaceBoxDataRate(rawValue: payload[2]) ?? .hz25
        flags = RaceBoxRecordingFlags(rawValue: payload[3])
        stationaryThresholdMmps = u16(4)
        stationaryIntervalSeconds = u16(6)
        noFixIntervalSeconds = u16(8)
        autoShutdownIntervalSeconds = u16(10)
    }
}

/// `0xFF 0x27` — GNSS receiver configuration (firmware 3.3+).
///
/// Writing this persists across restarts and, per the doc, a bad value can
/// render the device inoperable and voids warranty. Treat writes as dangerous.
public struct RaceBoxGnssConfig: Equatable, Sendable {
    /// u-blox CFG-NAVSPG-DYNMODEL. 4 = automotive (RaceBox default),
    /// 8 = airborne <4 g, for vehicles above 300 kph.
    public var dynamicPlatformModel: UInt8
    public var enable3DSpeed: Bool
    /// Fix is reported lost when horizontal accuracy is worse than this (metres).
    public var minimumHorizontalAccuracyMeters: UInt8

    public static let automotive = RaceBoxGnssConfig(
        dynamicPlatformModel: 4, enable3DSpeed: false, minimumHorizontalAccuracyMeters: 3)

    public init(dynamicPlatformModel: UInt8, enable3DSpeed: Bool,
                minimumHorizontalAccuracyMeters: UInt8) {
        self.dynamicPlatformModel = dynamicPlatformModel
        self.enable3DSpeed = enable3DSpeed
        self.minimumHorizontalAccuracyMeters = minimumHorizontalAccuracyMeters
    }

    public init?(payload: [UInt8]) {
        guard payload.count >= 3 else { return nil }
        dynamicPlatformModel = payload[0]
        enable3DSpeed = payload[1] != 0
        minimumHorizontalAccuracyMeters = payload[2]
    }

    public var payload: [UInt8] {
        [dynamicPlatformModel, enable3DSpeed ? 1 : 0, minimumHorizontalAccuracyMeters]
    }

    /// The device NACKs anything outside 0…8.
    public var isValid: Bool { dynamicPlatformModel <= 8 }
}

/// ACK (`0xFF 0x02`) / NACK (`0xFF 0x03`) — payload names the command answered.
public struct RaceBoxAcknowledgement: Equatable, Sendable {
    public let isPositive: Bool
    public let messageClass: UInt8
    public let messageID: UInt8

    public init?(packet: RaceBoxPacket) {
        guard packet.kind == .ack || packet.kind == .nack, packet.payload.count >= 2 else { return nil }
        isPositive = packet.kind == .ack
        messageClass = packet.payload[0]
        messageID = packet.payload[1]
    }
}

// MARK: - Command builders

public enum RaceBoxCommand {

    // Standalone recording
    public static func recordingStatusRequest() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x22)
    }
    public static func recordingConfigRequest() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x25)
    }
    public static func setRecording(_ config: RaceBoxRecordingConfig) -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x25, payload: config.payload)
    }
    /// Stopping ignores every other field, so send a bare disable.
    public static func stopRecording() -> RaceBoxPacket {
        setRecording(RaceBoxRecordingConfig(enabled: false))
    }

    // Memory download / erase
    public static func startDownload() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x23)
    }
    /// Any single-byte payload cancels; the device flushes, then ACKs.
    public static func cancelDownload() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x23, payload: [0xFF])
    }
    public static func eraseMemory() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x24)
    }
    public static func cancelErase() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x24, payload: [0xFF])
    }

    /// Memory lock resets on every connection — check status and unlock on connect.
    public static func unlockMemory(code: UInt32) -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x30, payload: [
            UInt8(code & 0xFF), UInt8((code >> 8) & 0xFF),
            UInt8((code >> 16) & 0xFF), UInt8((code >> 24) & 0xFF),
        ])
    }

    // GNSS receiver
    public static func gnssConfigRequest() -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x27)
    }
    public static func setGnssConfig(_ config: RaceBoxGnssConfig) -> RaceBoxPacket {
        RaceBoxPacket(messageClass: 0xFF, messageID: 0x27, payload: config.payload)
    }

    /// Expected record count returned when a download is accepted (`0xFF 0x23`).
    public static func downloadRecordCount(payload: [UInt8]) -> UInt32? {
        guard payload.count >= 4 else { return nil }
        return UInt32(payload[0]) | UInt32(payload[1]) << 8
            | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 24
    }

    /// Erase progress percentage from a `0xFF 0x24` notification.
    public static func eraseProgress(payload: [UInt8]) -> Int? {
        guard payload.count == 1 else { return nil }
        return Int(payload[0])
    }
}
