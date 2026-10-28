//
//  DragMeter.swift
//  SessionKit
//
//  Acceleration-run timing from a speed stream: detects a launch from a standstill
//  and records 0–60, 0–100 mph, 0–100, 0–200 km/h and the quarter-mile (time +
//  trap speed). Pure and
//  stateful; fed the same speed channel the dashboard shows. Distance is integrated
//  from speed, so it needs no GPS math.
//

import Foundation

public final class DragMeter: @unchecked Sendable {

    public struct Run: Equatable, Sendable {
        public var zeroToSixty: TimeInterval?
        public var zeroToHundred: TimeInterval?
        public var quarterMile: TimeInterval?
        public var quarterMileTrapKmh: Double?
        /// Metric splits, for drivers on km/h.
        public var zeroTo100Kmh: TimeInterval?
        public var zeroTo200Kmh: TimeInterval?
        public var launching: Bool = false
        public init(zeroToSixty: TimeInterval? = nil, zeroToHundred: TimeInterval? = nil,
                    quarterMile: TimeInterval? = nil, quarterMileTrapKmh: Double? = nil,
                    zeroTo100Kmh: TimeInterval? = nil, zeroTo200Kmh: TimeInterval? = nil,
                    launching: Bool = false) {
            self.zeroToSixty = zeroToSixty
            self.zeroToHundred = zeroToHundred
            self.quarterMile = quarterMile
            self.quarterMileTrapKmh = quarterMileTrapKmh
            self.zeroTo100Kmh = zeroTo100Kmh
            self.zeroTo200Kmh = zeroTo200Kmh
            self.launching = launching
        }

        public var isEmpty: Bool {
            zeroToSixty == nil && zeroToHundred == nil && quarterMile == nil
                && zeroTo100Kmh == nil && zeroTo200Kmh == nil
        }
    }

    private let mph60 = 26.8224      // m/s
    private let mph100 = 44.704
    private let kmh100 = 27.7778
    private let kmh200 = 55.5556
    private let quarterMeters = 402.336
    private let launchThreshold = 1.0
    private let stopThreshold = 0.5

    private var armed = true
    private var t0: TimeInterval?
    private var dist = 0.0
    private var last: (v: Double, t: TimeInterval)?
    public private(set) var current = Run()
    public private(set) var best = Run()

    public init() {}

    public func add(speedMps v: Double, t: TimeInterval) {
        defer { last = (v, t) }
        guard let prev = last else { return }
        let dt = t - prev.t
        guard dt > 0, dt < 2 else { return }

        // Launch detection: from a standstill, crossing the launch threshold.
        if armed, prev.v < launchThreshold, v >= launchThreshold {
            armed = false
            t0 = t
            dist = 0
            current = Run(launching: true)
        }
        guard let start = t0, current.launching else {
            if v < stopThreshold { armed = true }
            return
        }

        dist += v * dt
        let elapsed = t - start
        if current.zeroToSixty == nil, v >= mph60 { current.zeroToSixty = elapsed }
        if current.zeroToHundred == nil, v >= mph100 { current.zeroToHundred = elapsed }
        if current.zeroTo100Kmh == nil, v >= kmh100 { current.zeroTo100Kmh = elapsed }
        if current.zeroTo200Kmh == nil, v >= kmh200 { current.zeroTo200Kmh = elapsed }
        if current.quarterMile == nil, dist >= quarterMeters {
            current.quarterMile = elapsed
            current.quarterMileTrapKmh = v * 3.6
        }

        // End the run when the car slows to a stop (or the ¼ mile is done + coasting).
        if v < stopThreshold {
            current.launching = false
            armed = true
            mergeBest()
        }
    }

    /// Closes a run still in progress when the stream ends (a recording that
    /// stops mid-pull), so its splits count toward `best`.
    public func finish() {
        guard current.launching else { return }
        current.launching = false
        armed = true
        mergeBest()
    }

    private func mergeBest() {
        func better(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
            switch (a, b) { case let (x?, y?): return min(x, y); default: return a ?? b }
        }
        best.zeroToSixty = better(best.zeroToSixty, current.zeroToSixty)
        best.zeroToHundred = better(best.zeroToHundred, current.zeroToHundred)
        best.quarterMile = better(best.quarterMile, current.quarterMile)
        best.zeroTo100Kmh = better(best.zeroTo100Kmh, current.zeroTo100Kmh)
        best.zeroTo200Kmh = better(best.zeroTo200Kmh, current.zeroTo200Kmh)
        if best.quarterMile == current.quarterMile { best.quarterMileTrapKmh = current.quarterMileTrapKmh }
    }
}
