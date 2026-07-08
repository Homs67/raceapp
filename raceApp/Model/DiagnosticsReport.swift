//
//  DiagnosticsReport.swift
//  raceApp
//
//  Structured OBD-II capability report. Shared as JSON (machine-parseable, the
//  authoritative artifact for tuning the app to a specific car) with a
//  human-readable rendering for on-screen review.
//

import Foundation

struct DiagnosticsReport: Codable {
    var app = "raceApp Live Data"
    var generatedAt: String
    var isDemo: Bool
    var adapter: String?
    var elm: String?
    var obdProtocol: String?
    var vin: String?
    var gatt: String?
    var supportedPidCount: Int
    var multiPidSupported: Bool
    var sequentialHz: Double
    var multiPidHz: Double
    var milOn: Bool?
    var dtcCount: Int?
    var channels: [Channel]

    struct Channel: Codable {
        var name: String
        var pid: String
        var supported: Bool
        var value: Double?
        var unit: String
    }

    static func unavailable(generatedAt: String, isDemo: Bool) -> DiagnosticsReport {
        DiagnosticsReport(generatedAt: generatedAt, isDemo: isDemo, adapter: nil, elm: nil,
                          obdProtocol: nil, vin: nil, gatt: nil, supportedPidCount: 0,
                          multiPidSupported: false, sequentialHz: 0, multiPidHz: 0,
                          milOn: nil, dtcCount: nil, channels: [])
    }

    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    func readableText() -> String {
        var lines: [String] = []
        lines.append("RACEAPP · OBD-II DIAGNOSTICS")
        lines.append(generatedAt)
        lines.append("Adapter: \(isDemo ? "DEMO (simulated — not a real car)" : (adapter ?? "unknown"))")
        if let vin { lines.append("VIN: \(vin)") }
        if let elm { lines.append("ELM: \(elm)") }
        if let obdProtocol { lines.append("Protocol: \(obdProtocol)") }
        lines.append("")
        lines.append("CHANNELS (\(supportedPidCount) PIDs reported by ECU):")
        for channel in channels {
            if channel.supported {
                let value = channel.value.map { String(format: "%.2f %@", $0, channel.unit) } ?? "supported, no value"
                lines.append("  [\(channel.pid)] \(channel.name): \(value)")
            } else {
                lines.append("  [\(channel.pid)] \(channel.name): not supported")
            }
        }
        lines.append("")
        lines.append("Multi-PID request (RPM+speed+throttle in one call): \(multiPidSupported ? "SUPPORTED" : "not supported")")
        lines.append(String(format: "Fast-loop update rate: sequential ~%.1f Hz, multi-PID ~%.1f Hz", sequentialHz, multiPidHz))
        if let milOn {
            lines.append("Check engine: MIL \(milOn ? "ON" : "OFF"), \(dtcCount ?? 0) stored code(s)")
        }
        if let gatt, !isDemo {
            lines.append("")
            lines.append("BLUETOOTH / GATT:")
            lines.append(gatt)
        }
        return lines.joined(separator: "\n")
    }
}
