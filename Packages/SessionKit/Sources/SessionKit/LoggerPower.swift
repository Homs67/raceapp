//
//  LoggerPower.swift
//  SessionKit
//
//  What a logger's single power byte actually tells you.
//
//  A RaceBox Mini/Mini S reports battery percent directly. A Micro has no
//  battery and reports the voltage it is being fed, which could be the car's
//  12 V, a regulated 5 V supply, or a bare lithium cell — and only the last
//  of those says anything about remaining charge. Guessing a percentage from
//  a regulated 5 V rail would be inventing a number, so this type is explicit
//  about which case it is in.
//

import Foundation

public enum LoggerPower: Equatable, Sendable {

    /// The device has its own battery and told us the level.
    case battery(percent: Int, charging: Bool)
    /// Fed straight from one lithium cell, so voltage maps to a rough charge.
    case cell(volts: Double, percent: Int)
    /// A regulated supply — USB brick, boost converter, or the car. The cell
    /// behind a boost converter is invisible: its output holds steady until
    /// it collapses, so there is no charge to report, only whether the rail
    /// is still healthy.
    case supply(volts: Double, kind: SupplyKind, isLow: Bool)
    /// Below anything that makes sense.
    case unknown(volts: Double)

    public enum SupplyKind: Equatable, Sendable {
        case usb        // nominal 5 V
        case vehicle    // nominal 12 V

        public var nominal: Double { self == .usb ? 5 : 12 }
        /// Where a rail has sagged far enough to be worth saying so. A boost
        /// converter running a cell flat drops out of regulation shortly
        /// before it cuts off, which is the only warning that setup can give.
        public var lowThreshold: Double { self == .usb ? 4.8 : 11.8 }
    }

    /// Classify a reported input voltage.
    public static func from(inputVolts volts: Double) -> LoggerPower {
        switch volts {
        case 3.0...4.35:
            return .cell(volts: volts, percent: cellPercent(volts: volts))
        case 4.35...5.6:
            return .supply(volts: volts, kind: .usb, isLow: volts < SupplyKind.usb.lowThreshold)
        case 5.6...:
            return .supply(volts: volts, kind: .vehicle, isLow: volts < SupplyKind.vehicle.lowThreshold)
        default:
            return .unknown(volts: volts)
        }
    }

    /// Resting-voltage curve for one lithium-polymer cell. Under load a cell
    /// reads lower than at rest, so a loaded reading lands low on this curve —
    /// which errs toward saying the battery is flatter than it is. That is the
    /// right direction to be wrong in for a fuel gauge.
    ///
    /// Note the resolution limit: the protocol carries voltage in 0.1 V steps,
    /// and the middle of a lithium curve is nearly flat, so one step can be
    /// 20 points of charge. Treat the result as a quarter-tank indicator.
    static let curve: [(volts: Double, percent: Int)] = [
        (4.20, 100), (4.10, 90), (4.02, 80), (3.95, 70), (3.89, 60),
        (3.84, 50), (3.80, 40), (3.77, 30), (3.73, 20), (3.68, 10),
        (3.50, 5), (3.30, 0),
    ]

    public static func cellPercent(volts: Double) -> Int {
        if volts >= curve[0].volts { return 100 }
        if volts <= curve[curve.count - 1].volts { return 0 }
        for i in 0..<(curve.count - 1) {
            let high = curve[i], low = curve[i + 1]
            if volts <= high.volts, volts >= low.volts {
                let span = high.volts - low.volts
                guard span > 0 else { return low.percent }
                let f = (volts - low.volts) / span
                return Int((Double(low.percent) + f * Double(high.percent - low.percent)).rounded())
            }
        }
        return 0
    }

    /// Short label for a dashboard cell.
    public var shortText: String {
        switch self {
        case .battery(let percent, let charging):
            return "\(percent)%" + (charging ? " ⚡︎" : "")
        case .cell(_, let percent):
            return "≈\(percent)%"
        case .supply(let volts, _, _):
            return String(format: "%.1f V", volts)
        case .unknown(let volts):
            return String(format: "%.1f V", volts)
        }
    }

    /// True when the user should do something about it.
    public var needsAttention: Bool {
        switch self {
        case .battery(let percent, let charging): return percent <= 15 && !charging
        case .cell(_, let percent): return percent <= 15
        case .supply(_, _, let isLow): return isLow
        case .unknown: return true
        }
    }

    /// Why no percentage is shown, when there isn't one.
    public var explanation: String? {
        switch self {
        case .supply(_, .usb, let low):
            return low
                ? "Supply sagging — a battery pack behind a regulator is close to empty"
                : "Regulated 5 V supply: a battery behind it reads steady until it runs out"
        case .supply(_, .vehicle, let low):
            return low ? "Car voltage low" : nil
        case .unknown:
            return "Supply voltage out of range"
        case .battery, .cell:
            return nil
        }
    }
}
