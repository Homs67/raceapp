import Foundation
import ObdKit

/// Identity of one recorded scalar channel. Namespaced per 01-architecture §5:
/// `obd.*`, `gps.*`, `imu.*`, `baro.*`, `device.*`.
public struct ChannelId: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: ChannelId, rhs: ChannelId) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension ChannelId {
    // GPS (CoreLocation)
    static let gpsLatitude = ChannelId("gps.lat")
    static let gpsLongitude = ChannelId("gps.lon")
    static let gpsAltitude = ChannelId("gps.altitude")
    static let gpsSpeed = ChannelId("gps.speed")            // m/s
    static let gpsCourse = ChannelId("gps.course")          // degrees
    static let gpsHorizontalAccuracy = ChannelId("gps.hAcc") // ±m, honesty channel

    // IMU (CoreMotion, gravity-separated user acceleration in g)
    static let imuAccelX = ChannelId("imu.ax")
    static let imuAccelY = ChannelId("imu.ay")
    static let imuAccelZ = ChannelId("imu.az")
    static let imuYawRate = ChannelId("imu.yawRate")        // rad/s
    static let imuPitchRate = ChannelId("imu.pitchRate")
    static let imuRollRate = ChannelId("imu.rollRate")
    static let imuHeading = ChannelId("imu.heading")        // degrees

    // Car-frame G (auto-calibrated: leveled from gravity, aligned from the
    // first clean acceleration; lightly low-passed for gauge/graph use).
    // Raw device-frame imu.* channels are still recorded for reprocessing.
    static let carLatG = ChannelId("car.latG")   // +right / −left, g
    static let carLongG = ChannelId("car.longG") // +accel / −braking, g

    // Barometer
    static let baroRelativeAltitude = ChannelId("baro.relAltitude") // m

    // Device health
    static let deviceBattery = ChannelId("device.battery")  // 0…1
    static let deviceThermalState = ChannelId("device.thermal") // 0…3

    /// OBD channels reuse ObdKit's channel names: `obd.rpm`, `obd.speed`, …
    static func obd(_ channel: ObdChannel) -> ChannelId {
        ChannelId("obd." + channel.rawValue)
    }
}

/// One scalar sample. `t` is monotonic uptime seconds (same clock as ObdSample);
/// the session manifest anchors it to UTC once.
public struct ChannelSample: Sendable, Equatable {
    public let t: TimeInterval
    public let value: Double
    public init(t: TimeInterval, value: Double) {
        self.t = t
        self.value = value
    }
}
