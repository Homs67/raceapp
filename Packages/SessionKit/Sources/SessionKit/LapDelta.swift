//
//  LapDelta.swift
//  SessionKit
//
//  Live "delta to best lap": how far ahead (−) or behind (+) the current lap is
//  at the same point on the track. The reference is the session's best lap,
//  recorded as elapsed-time-at-distance in fixed 5 m bins; the running lap is
//  compared by interpolation at its current distance.
//
//  Every bin crossed between two consecutive samples is filled by linear
//  interpolation, so 1 Hz phone GPS (≈30 m per fix at 60 mph) leaves no holes.
//

import Foundation

public final class LapDelta: @unchecked Sendable {

    public let lapLength: Double
    public let binMeters: Double
    private let binCount: Int

    private var current: [TimeInterval?]
    private var reference: [TimeInterval?]
    private var hasReference = false
    private var lastSample: (s: Double, elapsed: TimeInterval)?
    private var latest: (s: Double, elapsed: TimeInterval)?

    public init(lapLength: Double, binMeters: Double = 5) {
        precondition(lapLength > 0)
        self.lapLength = lapLength
        self.binMeters = binMeters
        self.binCount = max(2, Int((lapLength / binMeters).rounded(.up)))
        current = [TimeInterval?](repeating: nil, count: binCount)
        reference = current
    }

    /// Feed progress for the running lap. `elapsed` = seconds since this lap's
    /// gate crossing.
    public func add(s: Double, elapsed: TimeInterval) {
        defer { lastSample = (s, elapsed); latest = (s, elapsed) }
        guard let prev = lastSample, elapsed >= prev.elapsed else { return }
        // Only fill forward within the same lap; a wrap is handled by lapCompleted.
        guard s >= prev.s else { return }
        let from = Int(prev.s / binMeters) + 1
        let to = Int(s / binMeters)
        guard to >= from else { return }
        let ds = s - prev.s
        for bin in from...min(to, binCount - 1) {
            let boundary = Double(bin) * binMeters
            let f = ds < 1e-9 ? 1 : (boundary - prev.s) / ds
            current[bin] = prev.elapsed + (elapsed - prev.elapsed) * f
        }
    }

    /// Call when LapTimer reports a completed lap. `isNewBest` is decided by the
    /// caller from the timer's own state so the two can never disagree.
    public func lapCompleted(lapTime: TimeInterval, isNewBest: Bool) {
        if isNewBest {
            var ref = current
            ref[0] = 0
            ref[binCount - 1] = lapTime
            Self.fillGaps(&ref)
            reference = ref
            hasReference = true
        }
        current = [TimeInterval?](repeating: nil, count: binCount)
        current[0] = 0
        lastSample = (0, 0)
        latest = nil
    }

    /// Delta at the most recently fed position; nil until a reference exists.
    public var delta: TimeInterval? {
        guard let latest else { return nil }
        return delta(at: latest.s, elapsed: latest.elapsed)
    }

    public func delta(at s: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard hasReference, s >= 0, s < lapLength else { return nil }
        let exact = s / binMeters
        let lo = Int(exact)
        let hi = min(lo + 1, binCount - 1)
        guard let a = reference[lo], let b = reference[hi] else { return nil }
        let f = exact - Double(lo)
        return elapsed - (a + (b - a) * f)
    }

    public func reset() {
        current = [TimeInterval?](repeating: nil, count: binCount)
        reference = current
        hasReference = false
        lastSample = nil
        latest = nil
    }

    /// Linear interpolation across nil runs, anchored by the filled bins either side.
    static func fillGaps(_ bins: inout [TimeInterval?]) {
        var i = 0
        while i < bins.count {
            guard bins[i] == nil else { i += 1; continue }
            let start = i
            while i < bins.count, bins[i] == nil { i += 1 }
            let end = i
            let before = start > 0 ? bins[start - 1] : nil
            let after = end < bins.count ? bins[end] : nil
            for k in start..<end {
                switch (before, after) {
                case let (b?, a?):
                    let f = Double(k - start + 1) / Double(end - start + 1)
                    bins[k] = b + (a - b) * f
                case let (b?, nil): bins[k] = b
                case let (nil, a?): bins[k] = a
                default: break
                }
            }
        }
    }
}
