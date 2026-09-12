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
    static let gpsVerticalAccuracy = ChannelId("gps.vAcc")   // ±m
    static let gpsSpeedAccuracy = ChannelId("gps.speedAcc")  // ±m/s
    /// CLLocation wall-clock timestamp as unix epoch seconds (for clock audits).
    static let gpsWallTime = ChannelId("gps.wallTime")

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

    // RaceBox logger (Mini / Mini S / Micro) — 25 Hz GNSS + car-rigid IMU.
    // Position/speed feed the canonical `gps.*` channels when RaceBox is the
    // active motion source (the manifest records which); these carry what only
    // the logger provides, plus its raw axes for reprocessing.
    static let rbSatellites = ChannelId("rb.sats")
    static let rbPdop = ChannelId("rb.pdop")
    static let rbFixStatus = ChannelId("rb.fixStatus")    // 0 none, 2 = 2D, 3 = 3D
    static let rbGForceX = ChannelId("rb.gx")             // g, sensor frame
    static let rbGForceY = ChannelId("rb.gy")
    static let rbGForceZ = ChannelId("rb.gz")
    static let rbRollRate = ChannelId("rb.rollRate")      // °/s
    static let rbPitchRate = ChannelId("rb.pitchRate")
    static let rbYawRate = ChannelId("rb.yawRate")
    static let rbPower = ChannelId("rb.power")            // volts (Micro) or battery %
    /// GNSS-disciplined UTC from the device — a better clock than the phone's
    /// for aligning video, and the way to measure any drift between them.
    static let rbWallTime = ChannelId("rb.wallTime")

    /// Phone GPS kept as an independent cross-check while a logger owns `gps.*`.
    static let phoneLatitude = ChannelId("phone.lat")
    static let phoneLongitude = ChannelId("phone.lon")
    static let phoneSpeed = ChannelId("phone.speed")

    // Broadcast CAN signals (per-model map, ND verified 2026-07: steering 0x086,
    // brake 0x078, pedal+rpm 0x202; wheelSpeed 0x4B0 pending on-car check).
    // 50–105 Hz vs ~7.5 Hz OBD polling. Adapter-alive like obd.* for gap logic.
    static let canSteering = ChannelId("can.steering")      // degrees, + = right
    static let canBrake = ChannelId("can.brake")            // %
    static let canAccelPedal = ChannelId("can.accelPedal")  // %
    static let canRpm = ChannelId("can.rpm")
    static let canWheelSpeed = ChannelId("can.wheelSpeed")  // km/h, 4-wheel avg

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
