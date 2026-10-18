//
//  LoggerFrameTracker.swift
//  SessionKit
//
//  Car-frame G from an external logger's accelerometer (RaceBox).
//
//  Worth the extra machinery because the logger is bolted to the OBD port
//  while the phone sits in a cradle: replaying the 2026-09-16 ND2 drive
//  through this path put the forward axis 8.0° out (scale 0.990) where the
//  phone's own IMU managed 50.8° (scale 0.632).
//

import Foundation

public struct LoggerFrameTracker: Sendable {

    /// CoreMotion hands the phone gravity and linear acceleration already
    /// separated; a logger reports only their sum. The car's attitude changes
    /// over seconds and real acceleration over tenths of one, so a slow EMA
    /// recovers gravity and the remainder is the linear part the alignment
    /// needs.
    ///
    /// 30 s, chosen by replaying the ND2 drive and scoring the result with
    /// GForceValidator's own metric: 5 s scored 0.766 (still "marginal"),
    /// 10 s 0.904, 30 s 0.996, and it plateaus after that. A short constant
    /// high-passes away the gentle, seconds-long accelerations the validator
    /// averages over. Safe to make this long only because of the gate below.
    private static let gravityTau: TimeInterval = 30

    /// …but only while the car is near coasting. An EMA that keeps averaging
    /// through a long corner mistakes the cornering force for gravity and
    /// subtracts it away: a steady 0.8 g corner decayed to 0.24 g after six
    /// seconds and 0.07 g after twelve. Freezing the estimate whenever total
    /// specific force leaves a narrow band around 1 g holds it at 0.80
    /// indefinitely. ±0.03 g ≈ 0.25 g of combined horizontal acceleration.
    ///
    /// Grade changes still come through: climbing at a steady speed the
    /// accelerometer reads 1 g exactly, just rotated, so the gate stays open
    /// and the estimate follows the new attitude.
    private static let quietBand = 0.03
    /// ~1.5 s at the RaceBox's 25 Hz.
    private static let levelingSamples = 38

    private var calibrator = CarFrameCalibrator(levelingSamplesNeeded: levelingSamples)
    private var gravity: Vector3?
    private var lastT: TimeInterval?

    public init() {}

    public var phase: CarFrameCalibrator.Phase { calibrator.phase }
    public var fitQuality: CarFrameCalibrator.FitQuality? { calibrator.fitQuality }

    public mutating func reset() {
        calibrator = CarFrameCalibrator(levelingSamplesNeeded: Self.levelingSamples)
        gravity = nil
        lastT = nil
    }

    /// Ground speed for the alignment fit. Only call with a valid fix.
    public mutating func ingestSpeed(_ mps: Double, at t: TimeInterval) {
        calibrator.ingestSpeed(mps, at: t)
    }

    /// One accelerometer sample in g, gravity included, in logger axes.
    /// Returns car-frame G once the alignment has converged.
    @discardableResult
    public mutating func ingest(accel: Vector3, rotationRate: Vector3? = nil,
                                at t: TimeInterval) -> (latG: Double, longG: Double)? {
        let dt = lastT.map { max(1e-3, t - $0) } ?? 0
        lastT = t
        guard let current = gravity else {
            gravity = accel          // at rest the first sample is gravity
            return nil
        }
        // A gap (disconnect, parked with the app backgrounded) would let the
        // EMA jump; re-seed instead of smearing the step across the estimate.
        guard dt < 2 else {
            gravity = accel
            return nil
        }
        // Only a coasting sample is a trustworthy gravity reference.
        let manoeuvring = abs(accel.magnitude - 1) > Self.quietBand
        let alpha = manoeuvring ? 0 : 1 - exp(-dt / Self.gravityTau)
        let updated = current + (accel - current) * alpha
        gravity = updated
        let linear = accel - updated
        // The logger reports specific force: at rest the vector points UP
        // (+1 g), where CoreMotion's `gravity` points down. Verified against
        // the ND2 drive — taking the un-negated vector as "down" mirrors the
        // lateral axis (its correlation with the GPS turn rate flips sign).
        calibrator.ingestMotion(gravity: (updated * -1).normalized, userAccel: linear,
                                rotationRate: rotationRate)
        return calibrator.carFrame(userAccel: linear)
    }
}
