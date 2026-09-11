import Foundation

/// Turns "is the RaceBox working?" into a list of pass/fail assertions, so a
/// single screenshot answers the question instead of a human squinting at
/// numbers. Pure logic — evaluated over a window of live messages plus link
/// stats, and unit-tested without hardware.
public struct RaceBoxSelfTest: Sendable {

    public enum Status: String, Sendable {
        case pass
        case fail
        /// Not applicable right now (e.g. at-rest checks while moving).
        case skipped
    }

    public struct Check: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let status: Status
        /// What was actually measured, so a failure is self-explanatory.
        public let detail: String

        public init(id: String, title: String, status: Status, detail: String) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
        }
    }

    /// A device is "at rest" below this speed — the gravity and gyro checks
    /// only mean something when it isn't moving.
    public static let restSpeedMps = 0.5

    public static func evaluate(messages: [RaceBoxDataMessage],
                                stats: RaceBoxLinkStats,
                                model: RaceBoxModel?,
                                now: Date = Date()) -> [Check] {
        guard let latest = messages.last else {
            return [Check(id: "data", title: "Receiving data", status: .fail,
                          detail: "no data messages received")]
        }
        var checks: [Check] = []

        // Link
        checks.append(Check(
            id: "rate", title: "Packet rate ≥ 20 Hz",
            status: stats.measuredHz >= 20 ? .pass : .fail,
            detail: String(format: "%.1f Hz measured", stats.measuredHz)))

        checks.append(Check(
            id: "checksum", title: "No checksum errors",
            status: stats.checksumFailures == 0 ? .pass : .fail,
            detail: stats.checksumFailures == 0
                ? "\(stats.packetsParsed) packets clean"
                : "\(stats.checksumFailures) of \(stats.packetsParsed) failed"))

        checks.append(Check(
            id: "framing", title: "Clean reassembly",
            status: stats.bytesDiscarded == 0 ? .pass : .fail,
            detail: stats.bytesDiscarded == 0
                ? "no bytes discarded"
                : "\(stats.bytesDiscarded) bytes discarded resyncing"))

        // Fix
        checks.append(Check(
            id: "fix", title: "3D GNSS fix",
            status: latest.hasValidFix ? .pass : .fail,
            detail: latest.hasValidFix
                ? "\(latest.satellites) satellites, PDOP \(String(format: "%.2f", latest.pdop))"
                : "fix status \(latest.fixStatus.rawValue), \(latest.satellites) satellites"))

        if latest.hasValidFix {
            checks.append(Check(
                id: "accuracy", title: "Horizontal accuracy < 10 m",
                status: latest.horizontalAccuracy < 10 ? .pass : .fail,
                detail: String(format: "±%.2f m", latest.horizontalAccuracy)))

            let plausible = latest.coordinatesValid
                && abs(latest.latitude) <= 90 && abs(latest.longitude) <= 180
                && !(latest.latitude == 0 && latest.longitude == 0)
            checks.append(Check(
                id: "position", title: "Plausible coordinates",
                status: plausible ? .pass : .fail,
                detail: String(format: "%.6f, %.6f", latest.latitude, latest.longitude)))
        } else {
            checks.append(Check(id: "accuracy", title: "Horizontal accuracy < 10 m",
                                status: .skipped, detail: "needs a fix"))
            checks.append(Check(id: "position", title: "Plausible coordinates",
                                status: .skipped, detail: "needs a fix"))
        }

        // Clock — GNSS time is authoritative; a big delta means our timestamps
        // (and therefore video sync) would be wrong.
        if latest.timeFullyResolved, let deviceTime = latest.timestamp {
            let delta = abs(deviceTime.timeIntervalSince(now))
            checks.append(Check(
                id: "clock", title: "UTC within 2 s of phone",
                status: delta <= 2 ? .pass : .fail,
                detail: String(format: "%.1f s difference", delta)))
        } else {
            checks.append(Check(id: "clock", title: "UTC within 2 s of phone",
                                status: .skipped, detail: "time not yet resolved"))
        }

        // Sensors — only meaningful while stationary
        let atRest = latest.speedMps < restSpeedMps
        if atRest {
            let g = latest.gForce.magnitude
            checks.append(Check(
                id: "gravity", title: "Gravity ≈ 1.0 g at rest",
                status: abs(g - 1.0) <= 0.15 ? .pass : .fail,
                detail: String(format: "|G| = %.3f g", g)))

            let spin = latest.rotationRate.magnitude
            checks.append(Check(
                id: "gyro", title: "Gyro ≈ 0 °/s at rest",
                status: spin <= 5 ? .pass : .fail,
                detail: String(format: "%.2f °/s", spin)))
        } else {
            let detail = String(format: "moving at %.1f m/s", latest.speedMps)
            checks.append(Check(id: "gravity", title: "Gravity ≈ 1.0 g at rest",
                                status: .skipped, detail: detail))
            checks.append(Check(id: "gyro", title: "Gyro ≈ 0 °/s at rest",
                                status: .skipped, detail: detail))
        }

        // Power
        if let model {
            switch latest.power(for: model) {
            case .inputVoltage(let volts):
                // The Micro runs on vehicle 12 V in the car and ~5 V on a USB
                // bench cable. Both are healthy; anything else is a fault.
                let vehicle = (11.0...15.0).contains(volts)
                let usb = (4.5...5.5).contains(volts)
                checks.append(Check(
                    id: "power", title: "Input voltage healthy",
                    status: (vehicle || usb) ? .pass : .fail,
                    detail: String(format: "%.1f V%@", volts,
                                   vehicle ? " (vehicle)" : usb ? " (USB bench power)" : " — expected ~12 V in car")))
            case .battery(let percent, let charging):
                checks.append(Check(
                    id: "power", title: "Battery above 0 %",
                    status: percent > 0 ? .pass : .fail,
                    detail: "\(percent)%\(charging ? ", charging" : "")"))
            }
        }

        return checks
    }

    /// One-line verdict for the header.
    public static func summary(_ checks: [Check]) -> (passed: Int, failed: Int, skipped: Int) {
        (checks.filter { $0.status == .pass }.count,
         checks.filter { $0.status == .fail }.count,
         checks.filter { $0.status == .skipped }.count)
    }
}
