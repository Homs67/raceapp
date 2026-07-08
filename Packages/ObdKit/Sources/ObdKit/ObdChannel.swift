import Foundation

/// A single OBD-II data channel we poll. PID assignments per 03-obd2-integration.md §8.
public enum ObdChannel: String, CaseIterable, Sendable, Codable {
    // Fast loop
    case rpm
    case speed
    case throttle
    case acceleratorPedal

    // Slow loop
    case engineLoad
    case coolantTemp
    case intakeAirTemp
    case manifoldPressure
    case mafRate
    case fuelLevel
    case barometricPressure
    case controlModuleVoltage
    case ambientTemp
    case oilTemp
    case timingAdvance

    /// Mode 01 PID.
    public var pid: UInt8 {
        switch self {
        case .rpm: return 0x0C
        case .speed: return 0x0D
        case .throttle: return 0x11
        case .acceleratorPedal: return 0x49
        case .engineLoad: return 0x04
        case .coolantTemp: return 0x05
        case .intakeAirTemp: return 0x0F
        case .manifoldPressure: return 0x0B
        case .mafRate: return 0x10
        case .fuelLevel: return 0x2F
        case .barometricPressure: return 0x33
        case .controlModuleVoltage: return 0x42
        case .ambientTemp: return 0x46
        case .oilTemp: return 0x5C
        case .timingAdvance: return 0x0E
        }
    }

    public init?(pid: UInt8) {
        guard let match = Self.allCases.first(where: { $0.pid == pid }) else { return nil }
        self = match
    }

    public var unit: String {
        switch self {
        case .rpm: return "rpm"
        case .speed: return "km/h"
        case .throttle, .acceleratorPedal, .engineLoad, .fuelLevel: return "%"
        case .coolantTemp, .intakeAirTemp, .ambientTemp, .oilTemp: return "°C"
        case .manifoldPressure, .barometricPressure: return "kPa"
        case .mafRate: return "g/s"
        case .controlModuleVoltage: return "V"
        case .timingAdvance: return "°"
        }
    }

    // Accelerator pedal is a fast-changing driver input (truer than throttle body
    // on drive-by-wire), so it rides the fast loop. Cars that don't report a
    // channel simply get it dropped after the first NO DATA.
    public static let defaultFastLoop: [ObdChannel] = [.rpm, .speed, .throttle, .acceleratorPedal]

    public static let defaultSlowLoop: [ObdChannel] = [
        .coolantTemp, .oilTemp, .intakeAirTemp, .ambientTemp,
        .fuelLevel, .controlModuleVoltage, .engineLoad,
        .barometricPressure, .timingAdvance, .manifoldPressure, .mafRate,
    ]
}

/// One decoded sample. `timestamp` is monotonic uptime in seconds,
/// mapped to UTC once per session by the recording layer.
public struct ObdSample: Sendable, Equatable {
    public let channel: ObdChannel
    public let value: Double
    public let timestamp: TimeInterval

    public init(channel: ObdChannel, value: Double, timestamp: TimeInterval) {
        self.channel = channel
        self.value = value
        self.timestamp = timestamp
    }
}

/// Monotonic now, in seconds since boot.
public func monotonicNow() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
