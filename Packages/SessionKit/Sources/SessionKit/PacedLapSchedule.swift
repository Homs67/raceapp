//
//  PacedLapSchedule.swift
//  SessionKit
//
//  Demo laps with varying pace. TrackDriveSimulator is deterministic, so every
//  lap is identical and a delta would read 0.00 forever; this drives lap k with
//  its own pace so the demo shows a real, signed delta. Position is continuous
//  at lap boundaries (every simulator starts at centerline[0]); only speed
//  steps by a few percent at the line.
//

import Foundation

public struct PacedLapSchedule: Sendable {

    private let sims: [TrackDriveSimulator]
    private let lapStarts: [TimeInterval]   // cumulative start time of lap k within one cycle
    private let cycleTime: TimeInterval
    public let lapTimes: [TimeInterval]
    public let lapLengthMeters: Double

    public init(centerline: [GeoPoint],
                paces: [Double] = [0.85, 0.82, 0.87, 0.84, 0.89],
                base: TrackDriveSimulator.Config = .init()) {
        precondition(!paces.isEmpty)
        sims = paces.map { pace in
            var config = base
            config.pace = pace
            return TrackDriveSimulator(centerline: centerline, config: config)
        }
        var starts: [TimeInterval] = []
        var acc = 0.0
        for sim in sims {
            starts.append(acc)
            acc += sim.lapTime
        }
        lapStarts = starts
        cycleTime = acc
        lapTimes = sims.map(\.lapTime)
        lapLengthMeters = sims[0].lapLengthMeters
    }

    public func sample(atElapsed elapsed: TimeInterval) -> TrackDriveSimulator.Sample {
        let cycles = Int(floor(elapsed / cycleTime))
        let inCycle = elapsed - Double(cycles) * cycleTime
        var k = lapStarts.count - 1
        while k > 0, lapStarts[k] > inCycle { k -= 1 }
        let sim = sims[k]
        let local = min(inCycle - lapStarts[k], sim.lapTime - 1e-6)
        let s = sim.sample(atElapsed: local)
        return TrackDriveSimulator.Sample(
            lap: cycles * sims.count + k,
            distance: s.distance, position: s.position, headingDeg: s.headingDeg,
            speedMps: s.speedMps, lateralG: s.lateralG, longitudinalG: s.longitudinalG)
    }
}
