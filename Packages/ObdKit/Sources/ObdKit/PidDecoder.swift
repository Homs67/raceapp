import Foundation

/// Pure functions: raw ELM response payloads → engineering values.
/// Formulas per SAE J1979. Everything here is deterministic and unit-tested.
public enum PidDecoder {

    /// Data-byte count per mode-01 PID (needed to walk multi-PID responses).
    public static func byteCount(forPid pid: UInt8) -> Int? {
        switch pid {
        case 0x00, 0x20, 0x40, 0x60: return 4 // supported-PID bitmaps
        case 0x01: return 4                   // MIL / DTC status
        case 0x04, 0x05, 0x0B, 0x0D, 0x0E, 0x0F, 0x11, 0x2F, 0x33, 0x46, 0x49, 0x4A, 0x5C: return 1
        case 0x0C, 0x10, 0x42: return 2
        default: return nil
        }
    }

    /// Engineering value for a single mode-01 PID.
    public static func decode(pid: UInt8, bytes: [UInt8]) -> Double? {
        guard let expected = byteCount(forPid: pid), bytes.count >= expected else { return nil }
        let a = Double(bytes[0])
        let b = bytes.count > 1 ? Double(bytes[1]) : 0
        switch pid {
        case 0x04: return a * 100 / 255              // engine load %
        case 0x05: return a - 40                     // coolant °C
        case 0x0B: return a                          // MAP kPa
        case 0x0C: return (a * 256 + b) / 4          // RPM
        case 0x0D: return a                          // speed km/h
        case 0x0E: return a / 2 - 64                 // timing advance °
        case 0x0F: return a - 40                     // intake air °C
        case 0x10: return (a * 256 + b) / 100        // MAF g/s
        case 0x11: return a * 100 / 255              // throttle %
        case 0x2F: return a * 100 / 255              // fuel level %
        case 0x33: return a                          // barometric kPa
        case 0x42: return (a * 256 + b) / 1000       // module voltage V
        case 0x46: return a - 40                     // ambient °C
        case 0x49, 0x4A: return a * 100 / 255        // accelerator pedal %
        case 0x5C: return a - 40                     // oil temp °C
        default: return nil
        }
    }

    /// Normalize raw ELM response lines (post ATS0/ATH0) into a flat byte array.
    /// Handles multi-frame ISO-TP formatting: strips "0:", "1:" line indices and
    /// the 3-digit length header line, tolerates stray spaces.
    public static func payloadBytes(fromLines lines: [String]) -> [UInt8] {
        var hex = ""
        for rawLine in lines {
            var line = rawLine.uppercased().replacingOccurrences(of: " ", with: "")
            if let colon = line.firstIndex(of: ":") {
                let prefix = line[line.startIndex..<colon]
                if prefix.count <= 2, prefix.allSatisfy(\.isHexDigit) {
                    line = String(line[line.index(after: colon)...])
                }
            }
            // ISO-TP length header ("014") — odd-length short line, not data
            if line.count <= 3, line.count % 2 == 1 { continue }
            hex += line.filter(\.isHexDigit)
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }

    /// Walk a mode-01 response (single- or multi-PID) into (pid, value) pairs.
    /// Example: "410C1AF80D3C1145" → RPM 1726, speed 60, throttle 27.06.
    public static func decodeMode01(lines: [String]) -> [(pid: UInt8, value: Double)] {
        let bytes = payloadBytes(fromLines: lines)
        guard bytes.first == 0x41 else { return [] }
        var results: [(UInt8, Double)] = []
        var i = 1
        while i < bytes.count {
            let pid = bytes[i]
            i += 1
            guard let len = byteCount(forPid: pid), i + len <= bytes.count else { break }
            if let value = decode(pid: pid, bytes: Array(bytes[i..<(i + len)])) {
                results.append((pid, value))
            }
            i += len
        }
        return results
    }

    /// Supported-PID bitmap (PIDs 0x00/0x20/0x40/0x60) → set of supported PIDs.
    public static func supportedPids(basePid: UInt8, bytes: [UInt8]) -> Set<UInt8> {
        var pids: Set<UInt8> = []
        for (byteIndex, byte) in bytes.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                pids.insert(basePid + UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return pids
    }

    /// Mode 09 PID 02 (VIN) — multi-frame response → 17-character VIN.
    public static func decodeVin(lines: [String]) -> String? {
        let bytes = payloadBytes(fromLines: lines)
        guard let start = firstIndex(of: [0x49, 0x02], in: bytes) else { return nil }
        // Skip 49 02 + message-count byte, keep printable ASCII
        let payload = bytes.dropFirst(start + 3)
        let chars = payload.compactMap { byte -> Character? in
            guard byte >= 0x20, byte < 0x7F else { return nil }
            let ch = Character(UnicodeScalar(byte))
            return ch.isLetter || ch.isNumber ? ch : nil
        }
        guard chars.count >= 17 else { return nil }
        return String(chars.prefix(17))
    }

    /// Mode 01 PID 01 — MIL lamp state and stored DTC count.
    public static func decodeDtcStatus(lines: [String]) -> (milOn: Bool, dtcCount: Int)? {
        let bytes = payloadBytes(fromLines: lines)
        guard bytes.count >= 3, bytes[0] == 0x41, bytes[1] == 0x01 else { return nil }
        let a = bytes[2]
        return (milOn: a & 0x80 != 0, dtcCount: Int(a & 0x7F))
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<(i + pattern.count)]) == pattern {
            return i
        }
        return nil
    }
}
