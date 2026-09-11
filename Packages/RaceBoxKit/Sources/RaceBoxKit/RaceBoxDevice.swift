import Foundation
import BleKit

/// Which RaceBox we are talking to. Capabilities differ enough that commands
/// must be gated on it — sending a recording command to a plain Mini returns
/// an error or nothing at all.
public enum RaceBoxModel: String, CaseIterable, Sendable {
    case mini = "RaceBox Mini"
    case miniS = "RaceBox Mini S"
    case micro = "RaceBox Micro"

    /// From the Device Info Model characteristic, or the advertised name
    /// ("RaceBox Micro 1234567890"). Order matters: "RaceBox Mini S" also has
    /// the "RaceBox Mini" prefix.
    public static func parse(_ text: String?) -> RaceBoxModel? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix(Self.miniS.rawValue) { return .miniS }
        if text.hasPrefix(Self.micro.rawValue) { return .micro }
        if text.hasPrefix(Self.mini.rawValue) { return .mini }
        return nil
    }

    /// Mini has no internal storage; Mini S and Micro record standalone.
    public var supportsStandaloneRecording: Bool { self != .mini }
    /// The Micro is bus-powered and reports input voltage in the power byte.
    public var reportsInputVoltage: Bool { self == .micro }
    /// The Micro has no battery at all — it only runs on OBD-port 12 V.
    public var hasInternalBattery: Bool { self != .micro }
    /// Only the Micro has a physical start/stop button and persists its config.
    public var hasRecordingButton: Bool { self == .micro }
}

/// "major.minor" firmware revision, comparable for capability gating.
public struct RaceBoxFirmware: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(_ text: String?) {
        guard let text else { return nil }
        // Keep only version characters: real devices NUL-pad this field, and
        // "3.5\0" split on "." yields "5\0", which parses as nil → minor 0.
        // That silently reported firmware 3.5 as 3.0 and disabled every
        // 3.3-gated feature on a device that supports them.
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        let parts = cleaned.split(separator: ".")
        guard let major = Int(parts.first ?? "") else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
    }

    public static func < (lhs: RaceBoxFirmware, rhs: RaceBoxFirmware) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// Everything the Device Information service tells us, plus derived capabilities.
public struct RaceBoxDeviceInfo: Equatable, Sendable {
    public let model: RaceBoxModel?
    public let serialNumber: String?
    public let firmware: RaceBoxFirmware?
    public let hardwareRevision: String?
    public let manufacturer: String?

    public init(model: RaceBoxModel?, serialNumber: String?, firmware: RaceBoxFirmware?,
                hardwareRevision: String?, manufacturer: String?) {
        self.model = model
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.hardwareRevision = hardwareRevision
        self.manufacturer = manufacturer
    }

    public init(deviceInfo: [DeviceInfoCharacteristic: String]) {
        // Real devices pad these fixed-width characteristics with NUL bytes
        // (verified on a Micro: the serial arrives as "3242708836" + ten
        // 0x00). NUL is not whitespace, so it survives a plain trim — strip it
        // explicitly rather than trusting the caller.
        func text(_ key: DeviceInfoCharacteristic) -> String? {
            let cleaned = deviceInfo[key]?
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned?.isEmpty ?? true) ? nil : cleaned
        }
        self.init(model: RaceBoxModel.parse(text(.model)),
                  serialNumber: text(.serialNumber),
                  firmware: RaceBoxFirmware(text(.firmwareRevision)),
                  hardwareRevision: text(.hardwareRevision),
                  manufacturer: text(.manufacturer))
    }

    /// Features introduced in firmware 3.3.
    private static let fw33 = RaceBoxFirmware(major: 3, minor: 3)

    public var supportsStandaloneRecording: Bool { model?.supportsStandaloneRecording ?? false }
    public var supportsGnssConfig: Bool { (firmware.map { $0 >= Self.fw33 }) ?? false }
    public var supportsNmea: Bool { (firmware.map { $0 >= Self.fw33 }) ?? false }
    public var supports20HzRecording: Bool { (firmware.map { $0 >= Self.fw33 }) ?? false }

    public var displayName: String {
        let name = model?.rawValue ?? "RaceBox"
        guard let serialNumber else { return name }
        return "\(name) \(serialNumber)"
    }
}
