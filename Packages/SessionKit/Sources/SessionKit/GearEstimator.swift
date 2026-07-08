import Foundation

/// Derived gear from the speed/RPM ratio against a car's gearing table
/// (03 §8 "gear is derived, not read"). Constants per the design handoff.
public struct GearEstimator: Sendable {

    public struct Gearing: Sendable {
        public let ratios: [Double]
        public let finalDrive: Double
        public let tireCircumferenceMeters: Double

        public init(ratios: [Double], finalDrive: Double, tireCircumferenceMeters: Double) {
            self.ratios = ratios
            self.finalDrive = finalDrive
            self.tireCircumferenceMeters = tireCircumferenceMeters
        }

        /// MX-5 ND2 6MT, 195/50R16.
        public static let mx5nd2 = Gearing(
            ratios: [5.087, 2.991, 2.035, 1.594, 1.286, 1.000],
            finalDrive: 2.866,
            tireCircumferenceMeters: 1.888
        )
    }

    public let gearing: Gearing
    /// Accept a match when the observed overall ratio is within this fraction
    /// of a gear's nominal ratio — outside it means clutch in / shifting / coasting.
    /// 8% keeps adjacent close-ratio gears (ND2 3rd/4th) unambiguous while
    /// absorbing tire-diameter variance.
    public let tolerance: Double

    public init(gearing: Gearing = .mx5nd2, tolerance: Double = 0.08) {
        self.gearing = gearing
        self.tolerance = tolerance
    }

    /// 1-based gear, or nil for neutral / clutch-in / unresolvable.
    public func gear(rpm: Double, speedMps: Double) -> Int? {
        guard rpm > 500, speedMps > 2 else { return nil }
        let wheelRpm = speedMps * 60 / gearing.tireCircumferenceMeters
        let observed = rpm / wheelRpm
        for (index, ratio) in gearing.ratios.enumerated() {
            let nominal = ratio * gearing.finalDrive
            if abs(observed - nominal) / nominal <= tolerance {
                return index + 1
            }
        }
        return nil
    }
}
