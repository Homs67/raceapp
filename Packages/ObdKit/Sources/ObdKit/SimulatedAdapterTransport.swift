import Foundation

/// A fake Veepeak: speaks enough ELM327 to drive the entire real pipeline
/// (session → poller → decoder) with a parametric ND2 drive model.
/// Powers "Try with demo data" (R5.4) and App Store review.
public final class SimulatedAdapterTransport: ObdTransport, @unchecked Sendable {

    public static let demoVin = "JM1NDAM75K0313248"

    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let startUptime: TimeInterval

    public init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.startUptime = monotonicNow()
    }

    public func send(_ data: Data) async throws {
        guard let command = String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return }
        // Realistic BLE+adapter round-trip latency (~15 Hz effective on the fast loop)
        try? await Task.sleep(for: .milliseconds(55))
        respond(body(for: command))
    }

    private func respond(_ body: String) {
        continuation.yield(Data((body + "\r>").utf8))
    }

    private func body(for command: String) -> String {
        if command == "ATZ" { return "ELM327 v2.2" }
        if command.hasPrefix("AT") { return "OK" }
        if command == "0902" {
            // VIN over ISO-TP frames
            let hex = Self.demoVin.utf8.map { String(format: "%02X", $0) }.joined()
            let full = "490201" + hex
            let frames = stride(from: 0, to: full.count, by: 14).enumerated().map { index, offset -> String in
                let start = full.index(full.startIndex, offsetBy: offset)
                let end = full.index(start, offsetBy: min(14, full.count - offset))
                return "\(String(index, radix: 16).uppercased()):\(full[start..<end])"
            }
            return "014\r" + frames.joined(separator: "\r")
        }
        if command.hasPrefix("01") {
            return mode01Response(for: command)
        }
        return "?"
    }

    private func mode01Response(for command: String) -> String {
        // Strip mode prefix and optional expected-response-count suffix digit
        var pidHex = String(command.dropFirst(2))
        if pidHex.count % 2 == 1 { pidHex = String(pidHex.dropLast()) }
        var pids: [UInt8] = []
        var index = pidHex.startIndex
        while index < pidHex.endIndex, let next = pidHex.index(index, offsetBy: 2, limitedBy: pidHex.endIndex) {
            if let pid = UInt8(pidHex[index..<next], radix: 16) { pids.append(pid) }
            index = next
        }
        let model = DriveModel(t: monotonicNow() - startUptime)
        var payload = "41"
        for pid in pids {
            guard let bytes = model.bytes(forPid: pid) else { continue }
            payload += String(format: "%02X", pid)
            payload += bytes.map { String(format: "%02X", $0) }.joined()
        }
        return payload == "41" ? "NO DATA" : payload
    }

    /// Parametric canyon-run model: speed swells through corners, gears follow,
    /// RPM derived from ND2 gearing so the derived-gear display works in demo.
    struct DriveModel {
        let t: TimeInterval

        var speedKmh: Double {
            max(0, 65 + 45 * sin(t / 7.0) + 12 * sin(t / 2.3))
        }
        var gearRatio: Double {
            let ratios = [5.087, 2.991, 2.035, 1.594, 1.286, 1.000]
            switch speedKmh {
            case ..<25: return ratios[0]
            case ..<45: return ratios[1]
            case ..<70: return ratios[2]
            case ..<95: return ratios[3]
            case ..<120: return ratios[4]
            default: return ratios[5]
            }
        }
        var rpm: Double {
            let wheelRpm = speedKmh / 3.6 * 60 / 1.888 // 195/50R16 circumference
            return min(7400, max(850, wheelRpm * gearRatio * 2.866))
        }
        var throttlePct: Double {
            max(4, min(96, 50 + 45 * cos(t / 7.0)))
        }

        func bytes(forPid pid: UInt8) -> [UInt8]? {
            func u16(_ value: Double) -> [UInt8] {
                let v = UInt16(max(0, min(65535, value)))
                return [UInt8(v >> 8), UInt8(v & 0xFF)]
            }
            func pct(_ value: Double) -> [UInt8] { [UInt8(max(0, min(255, value * 255 / 100)))] }
            switch pid {
            case 0x0C: return u16(rpm * 4)
            case 0x0D: return [UInt8(max(0, min(255, speedKmh)))]
            case 0x11: return pct(throttlePct)
            case 0x49: return pct(throttlePct * 0.9)
            case 0x04: return pct(throttlePct * 0.8)
            case 0x05: return [UInt8(90 + 40)]                     // coolant 90°C
            case 0x0F: return [UInt8(31 + 40)]                     // IAT 31°C
            case 0x46: return [UInt8(24 + 40)]                     // ambient 24°C
            case 0x5C: return [UInt8(min(255, Int(96 + t / 60) + 40))] // oil warms slowly
            case 0x2F: return pct(max(8, 62 - t / 90))             // fuel burns
            case 0x42: return u16(14100 + 150 * sin(t / 3))        // 14.1 V
            case 0x33: return [101]
            case 0x0E: return [UInt8((12.0 + 64) * 2)]             // 12° BTDC
            case 0x00: return [0xBE, 0x3F, 0xA8, 0x13]             // supported PIDs 01-20
            case 0x20: return [0x90, 0x05, 0xB0, 0x15]             // includes 2F, 33, 42, 46 (+0x40 marker)
            case 0x40: return [0x7A, 0x1C, 0x80, 0x00]             // includes 42?46?49, 5C
            case 0x01: return [0x00, 0x07, 0x65, 0x04]             // MIL off, 0 codes
            default: return nil
            }
        }
    }
}
