import Foundation

/// Shared parametric demo drive used by both the simulated OBD adapter and the
/// demo phone-sensor feed, so RPM, speed, gear and G-forces all agree.
///
/// Models an aggressive street pull: launch in 1st and bang through gears 1→4,
/// shifting near ~5,900 rpm, then a brief engine-brake back down and repeat.
/// Speed is derived from (rpm, gear ratio) so it stays continuous across shifts
/// and the app's gear estimator resolves 1→4 correctly.
public struct DemoDrive {
    public let t: TimeInterval
    public init(t: TimeInterval) { self.t = t }

    private static let ratios = [5.087, 2.991, 2.035, 1.594] // ND2 gears 1–4
    private static let finalDrive = 2.866
    private static let tireCircumference = 1.888 // metres, 195/50R16
    private static let launchRpm = 2600.0
    private static let shiftRpm = 5900.0
    private static let accelPerGear = 3.2  // seconds accelerating in each gear
    private static let decel = 3.5         // seconds engine-braking back down
    private static var cycle: Double { Double(ratios.count) * accelPerGear + decel }

    private var phase: (gear: Int, rpm: Double, throttle: Double, accelerating: Bool) {
        let tc = t.truncatingRemainder(dividingBy: Self.cycle)
        let accelTotal = Double(Self.ratios.count) * Self.accelPerGear
        if tc < accelTotal {
            let gearIndex = Int(tc / Self.accelPerGear)
            let progress = (tc - Double(gearIndex) * Self.accelPerGear) / Self.accelPerGear
            // Start rpm chosen so speed is continuous across the upshift.
            let startRpm = gearIndex == 0
                ? Self.launchRpm
                : Self.shiftRpm * Self.ratios[gearIndex] / Self.ratios[gearIndex - 1]
            let rpm = startRpm + progress * (Self.shiftRpm - startRpm)
            let throttle = 90 + 6 * sin(progress * .pi)
            return (gearIndex + 1, rpm, throttle, true)
        } else {
            let progress = (tc - accelTotal) / Self.decel
            let rpm = Self.shiftRpm - progress * (Self.shiftRpm - 1600) // coast down in 4th
            return (Self.ratios.count, rpm, 2, false)
        }
    }

    public var gear: Int { phase.gear }
    public var rpm: Double { min(6400, max(900, phase.rpm)) }
    public var throttlePct: Double { phase.throttle }

    public var speedKmh: Double {
        let ratio = Self.ratios[min(Self.ratios.count - 1, max(0, phase.gear - 1))]
        return rpm / (ratio * Self.finalDrive) * Self.tireCircumference / 60 * 3.6
    }
    public var speedMps: Double { speedKmh / 3.6 }

    /// Longitudinal acceleration in g — the true derivative of this model's
    /// speed profile, so demo G-data is physically consistent with demo GPS
    /// (the in-app G-calibration verification cross-checks exactly this).
    public var longitudinalG: Double {
        let p = phase
        let kmhPerRpm = Self.tireCircumference / 60 * 3.6
            / (Self.ratios[min(Self.ratios.count - 1, max(0, p.gear - 1))] * Self.finalDrive)
        let rpmRate: Double // rpm per second in the current phase
        if p.accelerating {
            let startRpm = p.gear == 1
                ? Self.launchRpm
                : Self.shiftRpm * Self.ratios[p.gear - 1] / Self.ratios[p.gear - 2]
            rpmRate = (Self.shiftRpm - startRpm) / Self.accelPerGear
        } else {
            rpmRate = -(Self.shiftRpm - 1600) / Self.decel
        }
        let mps2 = rpmRate * kmhPerRpm / 3.6
        return mps2 / 9.81 + 0.03 * sin(t * 2.3)
    }
    /// Lateral acceleration in g (canyon corners), independent of the pull.
    public var lateralG: Double {
        0.7 * sin(t / 3.0) + 0.12 * sin(t / 1.1)
    }
}
