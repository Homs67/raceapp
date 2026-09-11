import Foundation

public struct RaceBoxVector3: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}

/// The 80-byte RaceBox Data Message (class 0xFF, ID 0x01 live / 0x21 history),
/// sent up to 25 times per second. Derived from u-blox NAV-PVT with the
/// accelerometer and gyroscope appended.
///
/// Every scale below is transcribed from the BLE Protocol doc rev 9 and locked
/// in by the golden-vector test built from the doc's own worked example.
public struct RaceBoxDataMessage: Equatable, Sendable {

    public static let payloadSize = 80

    public enum FixStatus: UInt8, Sendable {
        case none = 0
        case twoD = 2
        case threeD = 3
        case other = 255
    }

    /// Power reporting differs by model: Mini/Mini S carry a battery, the Micro
    /// is bus-powered and reports its input voltage in the same byte.
    public enum Power: Equatable, Sendable {
        case battery(percent: Int, charging: Bool)
        case inputVoltage(Double)
    }

    // Timing
    public let iTOW: UInt32               // ms into the GPS week
    public let year: Int
    public let month: Int                 // 1 = January
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let nanoseconds: Int32         // signed; may be negative
    public let validityFlags: UInt8
    public let timeAccuracyNs: UInt32

    // Fix quality
    public let fixStatus: FixStatus
    public let fixFlags: UInt8
    public let dateTimeFlags: UInt8
    public let satellites: Int
    public let pdop: Double
    public let latLonFlags: UInt8

    // Position (degrees / metres)
    public let latitude: Double
    public let longitude: Double
    public let wgsAltitude: Double
    public let mslAltitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double

    // Motion
    public let speedMps: Double
    public let headingDegrees: Double
    public let speedAccuracyMps: Double
    public let headingAccuracyDegrees: Double

    // Sensors — axes: G x front/back, y right/left, z up/down;
    // rotation x roll, y pitch, z yaw (°/s)
    public let gForce: RaceBoxVector3
    public let rotationRate: RaceBoxVector3

    /// Raw byte 67 — interpret with `power(for:)`, which needs the model.
    public let powerByte: UInt8

    // MARK: - Derived

    /// The doc's recommended test: 3D fix AND the valid-fix flag.
    public var hasValidFix: Bool { fixStatus == .threeD && (fixFlags & 0x01) != 0 }
    /// Bit 0 of the Lat/Lon flags means the coordinates are INVALID.
    public var coordinatesValid: Bool { (latLonFlags & 0x01) == 0 }
    public var dateValid: Bool { (validityFlags & 0x01) != 0 }
    public var timeValid: Bool { (validityFlags & 0x02) != 0 }
    public var timeFullyResolved: Bool { (validityFlags & 0x04) != 0 }
    public var headingValid: Bool { (fixFlags & 0x20) != 0 }

    /// UTC timestamp of the fix, nanosecond correction applied.
    public var timestamp: Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(Double(nanoseconds) / 1e9)
    }

    public func power(for model: RaceBoxModel) -> Power {
        model.reportsInputVoltage
            ? .inputVoltage(Double(powerByte) / 10)
            : .battery(percent: Int(powerByte & 0x7F), charging: (powerByte & 0x80) != 0)
    }

    // MARK: - Decoding

    public init?(payload: [UInt8]) {
        guard payload.count >= Self.payloadSize else { return nil }
        func u16(_ o: Int) -> UInt16 { UInt16(payload[o]) | UInt16(payload[o + 1]) << 8 }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(payload[o]) | UInt32(payload[o + 1]) << 8
                | UInt32(payload[o + 2]) << 16 | UInt32(payload[o + 3]) << 24
        }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }

        iTOW = u32(0)
        year = Int(u16(4))
        month = Int(payload[6])
        day = Int(payload[7])
        hour = Int(payload[8])
        minute = Int(payload[9])
        second = Int(payload[10])
        validityFlags = payload[11]
        timeAccuracyNs = u32(12)
        nanoseconds = i32(16)
        fixStatus = FixStatus(rawValue: payload[20]) ?? .other
        fixFlags = payload[21]
        dateTimeFlags = payload[22]
        satellites = Int(payload[23])
        longitude = Double(i32(24)) / 1e7
        latitude = Double(i32(28)) / 1e7
        wgsAltitude = Double(i32(32)) / 1000        // mm → m
        mslAltitude = Double(i32(36)) / 1000
        horizontalAccuracy = Double(u32(40)) / 1000
        verticalAccuracy = Double(u32(44)) / 1000
        speedMps = Double(i32(48)) / 1000           // mm/s → m/s
        headingDegrees = Double(i32(52)) / 1e5
        speedAccuracyMps = Double(u32(56)) / 1000
        headingAccuracyDegrees = Double(u32(60)) / 1e5
        pdop = Double(u16(64)) / 100
        latLonFlags = payload[66]
        powerByte = payload[67]
        gForce = RaceBoxVector3(x: Double(i16(68)) / 1000,   // milli-g → g
                                y: Double(i16(70)) / 1000,
                                z: Double(i16(72)) / 1000)
        rotationRate = RaceBoxVector3(x: Double(i16(74)) / 100, // centi-°/s → °/s
                                      y: Double(i16(76)) / 100,
                                      z: Double(i16(78)) / 100)
    }
}
