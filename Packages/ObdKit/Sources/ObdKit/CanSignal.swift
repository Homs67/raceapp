import Foundation

/// One raw CAN frame captured in ELM327 monitor mode.
public struct CanFrame: Equatable, Sendable {
    public let id: UInt32          // 11-bit arbitration ID
    public let data: [UInt8]       // payload bytes
    public let t: TimeInterval

    public init(id: UInt32, data: [UInt8], t: TimeInterval = 0) {
        self.id = id
        self.data = data
        self.t = t
    }
}

/// Bit/byte extraction helpers matching RaceChrono's equation conventions
/// (big-endian; `bitsToUInt` numbers bits from the MSB of byte 0).
public enum CanBits {
    public static func u16(_ b: [UInt8], _ offset: Int) -> UInt32? {
        guard offset + 1 < b.count else { return nil }
        return (UInt32(b[offset]) << 8) | UInt32(b[offset + 1])
    }

    public static func s16(_ b: [UInt8], _ offset: Int) -> Int? {
        guard let u = u16(b, offset) else { return nil }
        return Int(Int16(bitPattern: UInt16(u)))
    }

    public static func byte(_ b: [UInt8], _ offset: Int) -> UInt32? {
        guard offset < b.count else { return nil }
        return UInt32(b[offset])
    }

    /// `startBit` counts from the most-significant bit of byte 0.
    public static func bitsToUInt(_ b: [UInt8], _ startBit: Int, _ length: Int) -> UInt32? {
        guard startBit >= 0, length > 0, length <= 32, startBit + length <= b.count * 8 else { return nil }
        var value: UInt32 = 0
        for i in 0..<length {
            let bit = startBit + i
            let mask = UInt8(0x80) >> (bit % 8)
            let set = (b[bit / 8] & mask) != 0
            value = (value << 1) | (set ? 1 : 0)
        }
        return value
    }
}

/// A decodable broadcast-CAN signal: which frame carries it and how to scale it.
public struct CanSignal: Sendable {
    public let key: String     // channel-id suffix, e.g. "steeringAngle"
    public let name: String    // display name
    public let unit: String
    public let frameID: UInt32
    public let decode: @Sendable ([UInt8]) -> Double?

    public init(key: String, name: String, unit: String, frameID: UInt32,
                decode: @escaping @Sendable ([UInt8]) -> Double?) {
        self.key = key
        self.name = name
        self.unit = unit
        self.frameID = frameID
        self.decode = decode
    }
}

/// Per-vehicle broadcast-CAN signal maps. Advanced CAN data is proprietary and
/// per model/year, so each car needs its own map (community-sourced or RE'd).
/// This is the starting library — grows via bundled maps + user DBC import.
public enum CanSignalMap {

    /// Mazda MX-5 ND (500 kbps HS-CAN, standard OBD pins). Equations from the
    /// RaceChrono community map, tested on a 2019 ND RF. Steering scaling is
    /// non-linear (variable ratio) and centering can vary by model year.
    public static let mazdaND: [CanSignal] = [
        CanSignal(key: "steeringAngle", name: "Steering Angle", unit: "°", frameID: 0x086) { data in
            guard let u = CanBits.u16(data, 0) else { return nil }
            return (16000 - Double(u)) * 0.1 // + = turning right
        },
        CanSignal(key: "brakePos", name: "Brake Pedal", unit: "%", frameID: 0x078) { data in
            guard let raw = CanBits.bitsToUInt(data, 28, 12) else { return nil }
            return min(max(Double(raw) - 156, 0) / 2.56, 100)
        },
        CanSignal(key: "accelPedal", name: "Accelerator", unit: "%", frameID: 0x202) { data in
            guard let e = CanBits.byte(data, 4) else { return nil }
            return Double(e) / 2.5
        },
        CanSignal(key: "canRpm", name: "RPM (CAN)", unit: "rpm", frameID: 0x202) { data in
            guard let u = CanBits.u16(data, 0) else { return nil }
            return Double(u) / 4
        },
        CanSignal(key: "canSpeed", name: "Speed (CAN)", unit: "raw", frameID: 0x202) { data in
            guard let s = CanBits.s16(data, 2) else { return nil }
            return Double(s) / 360.0
        },
    ]

    /// Distinct frame IDs referenced by a signal set (for CAN filters).
    public static func frameIDs(_ signals: [CanSignal]) -> [UInt32] {
        var seen = Set<UInt32>()
        return signals.compactMap { seen.insert($0.frameID).inserted ? $0.frameID : nil }
    }
}

/// Parses ELM327 monitor-mode output lines into CAN frames. Tolerant of both
/// spaced (`ATS1`) and unspaced formats; 11-bit IDs only.
public enum CanFrameParser {

    /// Non-frame tokens the ELM emits during monitoring.
    static let noise: Set<String> = ["OK", "STOPPED", "BUFFERFULL", "CANERROR",
                                     "?", "SEARCHING", "NODATA", "UNABLETOCONNECT"]

    public static func parse(_ line: String, t: TimeInterval = 0) -> CanFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        if noise.contains(trimmed.replacingOccurrences(of: " ", with: "")) { return nil }

        // Spaced form: "086 3E 80 12 ..." → tokens[0] = ID, rest = bytes
        let tokens = trimmed.split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.count >= 2,
           tokens[0].count <= 3, tokens[0].allSatisfy(\.isHexDigit),
           let id = UInt32(tokens[0], radix: 16), id <= 0x7FF {
            let bytes = tokens.dropFirst().compactMap { UInt8($0, radix: 16) }
            if bytes.count == tokens.count - 1, !bytes.isEmpty {
                return CanFrame(id: id, data: bytes, t: t)
            }
        }

        // Unspaced form: "0863E8012..." → first 3 hex = ID, rest = byte pairs
        let hex = trimmed.filter(\.isHexDigit)
        guard hex.count >= 5, hex.count % 2 == 1 || hex.count % 2 == 0 else { return nil }
        // 11-bit ID is 3 hex nibbles; remaining must be an even number of nibbles
        guard hex.count >= 5, (hex.count - 3) % 2 == 0 else { return nil }
        let idString = String(hex.prefix(3))
        guard let id = UInt32(idString, radix: 16), id <= 0x7FF else { return nil }
        var bytes: [UInt8] = []
        let rest = Array(hex.dropFirst(3))
        var i = 0
        while i + 1 < rest.count {
            if let b = UInt8(String([rest[i], rest[i + 1]]), radix: 16) { bytes.append(b) }
            i += 2
        }
        guard !bytes.isEmpty else { return nil }
        return CanFrame(id: id, data: bytes, t: t)
    }
}
