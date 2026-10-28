//
//  SessionAnalysis.swift
//  raceApp
//
//  Everything the session summary and the full-screen track map show, worked
//  out once after the drive: the channels on one 10 Hz timeline, the laps with
//  out/in laps around them, the best lap, drag splits, brake zones and the gap
//  to the best lap. Built off-main from the recorded channels; pure afterwards.
//

import Foundation
import CoreLocation
import SwiftUI
import SessionKit
import ObdKit

/// A recorded channel the track map can chart.
enum AnalysisChannel: String, CaseIterable, Identifiable, Sendable {
    case speed, throttle, brake, steering, latG, longG, rpm, gear, elevation, load, coolant, gap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "Speed"
        case .throttle: return "Throttle"
        case .brake: return "Brake"
        case .steering: return "Steering"
        case .latG: return "Lat G"
        case .longG: return "Long G"
        case .rpm: return "RPM"
        case .gear: return "Gear"
        case .elevation: return "Elevation"
        case .load: return "Engine load"
        case .coolant: return "Coolant"
        case .gap: return "Gap to ★"
        }
    }

    var color: Color {
        switch self {
        case .speed: return .accent
        case .throttle: return Color(hex: 0x30D158)
        case .brake: return .recordRed
        case .steering: return Color(hex: 0xFFD60A)
        case .latG: return .white
        case .longG: return Color(hex: 0x64D2FF)
        case .rpm: return Color(hex: 0xBF5AF2)
        case .gear: return Color(hex: 0x8E8E93)
        case .elevation: return Color(hex: 0xAC8E68)
        case .load: return Color(hex: 0xFF9F0A)
        case .coolant: return Color(hex: 0x5AC8FA)
        case .gap: return Color(hex: 0xFF375F)
        }
    }

    /// Centre the axis on zero (G, steering, gap).
    var symmetric: Bool { self == .latG || self == .longG || self == .steering || self == .gap }

    func unit(_ units: UnitsFormatter) -> String {
        switch self {
        case .speed: return units.speedUnit.lowercased()
        case .throttle, .brake, .load: return "%"
        case .steering: return "°"
        case .latG, .longG: return "g"
        case .rpm, .gear: return ""
        case .elevation: return units.shortDistanceUnit
        case .coolant: return units.tempUnit
        case .gap: return "s"
        }
    }

    /// Stored values are SI (m/s, m, °C); this converts for display.
    func display(_ v: Double, _ units: UnitsFormatter) -> Double {
        switch self {
        case .speed: return units.speed(fromMps: v)
        case .elevation: return units.shortDistance(fromMeters: v)
        case .coolant: return units.temp(fromC: v)
        default: return v
        }
    }

    func format(_ v: Double, _ units: UnitsFormatter) -> String {
        let d = display(v, units)
        switch self {
        case .latG, .longG: return String(format: "%+.2f", d)
        case .gap: return String(format: "%+.2f", d)
        case .rpm: return d.formatted(.number.precision(.fractionLength(0)))
        case .gear: return d > 0 ? String(Int(d)) : "–"
        default: return String(format: "%.0f", d)
        }
    }
}

struct SessionAnalysis: Sendable {

    struct Lap: Identifiable, Sendable {
        enum Kind: Sendable { case outLap, timed, dnf, inLap, drive }
        var id: Int                  // position in `laps`
        var number: Int              // 1-based run index; 0 for out/in laps
        var kind: Kind
        var start: TimeInterval      // uptime, same base as channel samples
        var end: TimeInterval
        var duration: TimeInterval { end - start }
        var isTimed: Bool { kind == .timed }
        var label: String {
            switch kind {
            case .timed, .dnf: return "L\(number)"
            case .outLap: return "Out"
            case .inLap: return "In"
            case .drive: return "Drive"
            }
        }
    }

    struct BrakeZone: Identifiable, Sendable {
        var id: Int
        var corner: String
        var startIndex: Int          // into the session timeline
        var endIndex: Int
        var minIndex: Int
        var entrySpeed: Double       // m/s
        var minSpeed: Double
        var peakBrake: Double?       // % when the car reports a brake pedal
    }

    struct DragResult: Sendable {
        var zeroToSixty: TimeInterval?
        var zeroToHundredMph: TimeInterval?
        var zeroTo100Kmh: TimeInterval?
        var zeroTo200Kmh: TimeInterval?
        var quarterMile: TimeInterval?
        var quarterTrapMps: Double?
        // A crawl over a quarter mile is not a drag run: show the card only after a real pull.
        var isEmpty: Bool { zeroToSixty == nil && zeroTo100Kmh == nil }
    }

    static let hz = 10.0

    // Session timeline, 10 Hz.
    var t: [Double] = []
    var lat: [Double] = []
    var lon: [Double] = []
    var dist: [Double] = []          // cumulative metres
    var channels: [AnalysisChannel: [Double]] = [:]
    var brakeFromPedal = false
    var phoneGpsOnly = true

    /// Out lap, timed laps/runs (DNF included), in lap — in driving order.
    var laps: [Lap] = []
    var isLoop = true
    var bestLapId: Int?
    var drag = DragResult()
    var ambientC: Double?
    var corners: [(name: String, coordinate: CLLocationCoordinate2D)] = []

    var available: [AnalysisChannel] {
        AnalysisChannel.allCases.filter { $0 == .gap ? bestLapId != nil : channels[$0] != nil }
    }
    /// Laps to step through on the map; a drive with no laps is one long "lap".
    var navigableLaps: [Lap] {
        guard laps.isEmpty, t.count > 1 else { return laps }
        return [Lap(id: 0, number: 0, kind: .drive, start: t[0], end: t[t.count - 1])]
    }
    var timedLaps: [Lap] { laps.filter { $0.kind == .timed || $0.kind == .dnf } }
    var bestLap: Lap? { bestLapId.map { laps[$0] } }
    var speedRange: ClosedRange<Double> {
        let s = (bestLap.map { indices($0) }.map { Array(channels[.speed]?[$0] ?? []) }) ?? channels[.speed] ?? []
        guard let lo = s.min(), let hi = s.max(), hi > lo else { return 0...1 }
        return lo...hi
    }

    // MARK: - Lookups

    func indices(_ lap: Lap) -> ClosedRange<Int> {
        let a = index(at: lap.start), b = index(at: lap.end)
        return a...max(a, b)
    }

    /// Timeline index nearest an uptime.
    func index(at time: TimeInterval) -> Int {
        guard let first = t.first else { return 0 }
        return max(0, min(t.count - 1, Int(((time - first) * Self.hz).rounded())))
    }

    func coordinate(_ i: Int) -> CLLocationCoordinate2D { .init(latitude: lat[i], longitude: lon[i]) }

    func value(_ ch: AnalysisChannel, at i: Int, lap: Lap) -> Double? {
        if ch == .gap { return gap(lap)?[safe: i - indices(lap).lowerBound] }
        guard let v = channels[ch]?[safe: i], v.isFinite else { return nil }
        return v
    }

    /// Distance into the lap at timeline index `i`.
    func lapDistance(_ lap: Lap, _ i: Int) -> Double { dist[i] - dist[indices(lap).lowerBound] }
    func lapLength(_ lap: Lap) -> Double { let r = indices(lap); return dist[r.upperBound] - dist[r.lowerBound] }

    /// Seconds this lap is behind (+) the best lap at the same point, sample by
    /// sample. Points are matched by fraction of lap distance, so a lap that ran
    /// slightly wide still lines up corner to corner.
    func gap(_ lap: Lap) -> [Double]? {
        guard let best = bestLap else { return nil }
        let br = indices(best), r = indices(lap)
        let bLen = lapLength(best), len = lapLength(lap)
        guard bLen > 10, len > 10 else { return nil }
        let bu = br.map { (dist[$0] - dist[br.lowerBound]) / bLen }
        var out: [Double] = []
        out.reserveCapacity(r.count)
        var j = 0
        for i in r {
            let u = (dist[i] - dist[r.lowerBound]) / len
            while j < bu.count - 1, bu[j + 1] < u { j += 1 }
            let k = min(j + 1, bu.count - 1)
            let span = bu[k] - bu[j]
            let f = span > 0 ? (u - bu[j]) / span : 0
            let bt = (t[br.lowerBound + j] + (t[br.lowerBound + k] - t[br.lowerBound + j]) * f) - t[br.lowerBound]
            out.append((t[i] - t[r.lowerBound]) - bt)
        }
        return out
    }

    /// Braking stretches on a lap, one per corner, with entry and minimum speed.
    func brakeZones(_ lap: Lap) -> [BrakeZone] {
        let r = indices(lap)
        guard let speed = channels[.speed] else { return [] }
        let pedal = brakeFromPedal ? channels[.brake] : nil
        let longG = channels[.longG]
        func braking(_ i: Int) -> Bool {
            if let pedal { return pedal[i] >= 12 }
            if let g = longG?[i], g.isFinite { return g <= -0.35 }
            return false
        }
        var zones: [BrakeZone] = []
        var i = r.lowerBound
        while i <= r.upperBound {
            guard braking(i) else { i += 1; continue }
            var j = i
            while j <= r.upperBound, braking(j) { j += 1 }
            if j - i >= 4 {   // 0.4 s or more
                let tail = min(r.upperBound, j + Int(3 * Self.hz))
                let m = (i...tail).min { speed[$0] < speed[$1] } ?? i
                if speed[i] - speed[m] > 4 {   // a real slow-down, not a lift
                    let name = cornerName(near: m) ?? "Brake \(zones.count + 1)"
                    let peak = pedal.map { p in (i..<j).map { p[$0] }.max() ?? 0 }
                    if let last = zones.last, last.corner == name {
                        zones[zones.count - 1].endIndex = j - 1
                        if speed[m] < last.minSpeed { zones[zones.count - 1].minIndex = m; zones[zones.count - 1].minSpeed = speed[m] }
                        if let peak { zones[zones.count - 1].peakBrake = max(last.peakBrake ?? 0, peak) }
                    } else {
                        zones.append(BrakeZone(id: zones.count, corner: name, startIndex: i, endIndex: j - 1, minIndex: m,
                                               entrySpeed: speed[i], minSpeed: speed[m], peakBrake: peak))
                    }
                }
            }
            i = j
        }
        return zones
    }

    private func cornerName(near i: Int) -> String? {
        guard !corners.isEmpty else { return nil }
        let p = coordinate(i), mLon = 111_320 * cos(p.latitude * .pi / 180)
        let best = corners.min { a, b in
            func d(_ c: CLLocationCoordinate2D) -> Double {
                let dx = (c.longitude - p.longitude) * mLon, dy = (c.latitude - p.latitude) * 110_540
                return dx * dx + dy * dy
            }
            return d(a.coordinate) < d(b.coordinate)
        }
        return best?.name
    }

    // MARK: - Build

    static func build(directory: URL, manifest: SessionManifest, track: Track?) -> SessionAnalysis {
        var a = SessionAnalysis()
        let lats = ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: directory)
        let lons = ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: directory)
        guard lats.count > 2, lons.count > 2, let t0 = lats.first?.t, let t1 = lats.last?.t, t1 > t0 else { return a }
        let n = Int((t1 - t0) * hz) + 1
        a.t = (0..<n).map { t0 + Double($0) / hz }

        a.lat = resample(lats, a.t, hold: false)
        a.lon = resample(lons, a.t, hold: false)
        a.phoneGpsOnly = !(manifest.motionSourceSegments?.contains { $0.source == .raceBox } ?? false)

        func read(_ id: ChannelId) -> [ChannelSample]? {
            let s = ChannelReader.samples(for: id, inSessionDirectory: directory)
            return s.count > 1 ? s : nil
        }
        func put(_ ch: AnalysisChannel, _ samples: [ChannelSample]?, hold: Bool = false, _ f: (Double) -> Double = { $0 }) {
            guard let samples else { return }
            a.channels[ch] = resample(samples.map { ChannelSample(t: $0.t, value: f($0.value)) }, a.t, hold: hold)
        }

        // Speed in m/s: GPS first (it is what the laps were timed on), OBD as a fallback.
        if let gps = read(.gpsSpeed) { put(.speed, gps) } else { put(.speed, read(.obd(.speed))) { $0 / 3.6 } }
        put(.throttle, read(.canAccelPedal) ?? read(.obd(.throttle)))
        if let brake = read(.canBrake) { put(.brake, brake); a.brakeFromPedal = true }
        put(.steering, read(.canSteering))
        put(.latG, read(.carLatG) ?? read(.imuAccelX))
        put(.longG, read(.carLongG) ?? read(.imuAccelY))
        put(.rpm, read(.canRpm) ?? read(.obd(.rpm)))
        put(.elevation, read(.baroRelativeAltitude) ?? read(.gpsAltitude))
        put(.load, read(.obd(.engineLoad)))
        put(.coolant, read(.canCoolant) ?? read(.obd(.coolantTemp)), hold: true)
        if let rpm = a.channels[.rpm], let speed = a.channels[.speed] {
            let estimator = GearEstimator()
            a.channels[.gear] = zip(rpm, speed).map { Double(estimator.gear(rpm: $0, speedMps: $1) ?? 0) }
        }
        if let amb = read(.obd(.ambientTemp)) { a.ambientC = amb.map(\.value).reduce(0, +) / Double(amb.count) }

        // Distance along the drive, from speed (smoother than summed GPS steps).
        var d = 0.0
        a.dist = [0]
        let speed = a.channels[.speed] ?? []
        for i in 1..<n { d += max(0, speed[safe: i] ?? 0) / hz; a.dist.append(d) }

        // Laps: the timed runs, with the out lap before and the in lap after.
        let ref = manifest.track
        a.isLoop = ref?.layout?.isLoop ?? true
        let runs = ref?.runs ?? []
        if !runs.isEmpty {
            var laps: [Lap] = []
            if a.isLoop, let first = runs.first, first.start - t0 > 5 {
                laps.append(Lap(id: 0, number: 0, kind: .outLap, start: t0, end: first.start))
            }
            for run in runs {
                let end = run.end ?? min(t1, run.start + 300)
                laps.append(Lap(id: laps.count, number: run.index, kind: run.kind == .dnf ? .dnf : .timed, start: run.start, end: end))
            }
            if a.isLoop, let last = runs.last?.end, t1 - last > 5 {
                laps.append(Lap(id: laps.count, number: 0, kind: .inLap, start: last, end: t1))
            }
            a.laps = laps
            a.bestLapId = laps.filter { $0.kind == .timed }.min { $0.duration < $1.duration }?.id
        }
        if let track {
            a.corners = track.corners.map { ($0.name, $0.coordinate) }
        }

        // Drag splits over the native-rate speed stream.
        let meter = DragMeter()
        for s in read(.gpsSpeed) ?? [] { meter.add(speedMps: s.value, t: s.t) }
        meter.finish()
        let b = meter.best
        a.drag = DragResult(zeroToSixty: b.zeroToSixty, zeroToHundredMph: b.zeroToHundred,
                            zeroTo100Kmh: b.zeroTo100Kmh, zeroTo200Kmh: b.zeroTo200Kmh,
                            quarterMile: b.quarterMile, quarterTrapMps: b.quarterMileTrapKmh.map { $0 / 3.6 })
        return a
    }

    /// Linear (or sample-and-hold) resampling onto the timeline. Outside the
    /// channel's span, and across gaps longer than 2 s, values are NaN.
    private static func resample(_ s: [ChannelSample], _ grid: [Double], hold: Bool) -> [Double] {
        var out = [Double](repeating: .nan, count: grid.count)
        guard !s.isEmpty else { return out }
        var j = 0
        for (i, x) in grid.enumerated() {
            while j < s.count - 1, s[j + 1].t <= x { j += 1 }
            let a = s[j]
            if x < a.t { continue }
            guard j + 1 < s.count else { if x - a.t < 2 { out[i] = a.value }; continue }
            let b = s[j + 1]
            guard b.t - a.t < (hold ? 10 : 2) else { continue }
            out[i] = hold ? a.value : a.value + (b.value - a.value) * (x - a.t) / max(1e-6, b.t - a.t)
        }
        return out
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Blue (slow) → orange (fast), the colour key used on every speed map.
enum SpeedColor {
    static func color(_ u: Double) -> Color {
        let u = max(0, min(1, u))
        return Color(red: (74 + (255 - 74) * u) / 255, green: (125 + (90 - 125) * u) / 255, blue: (255 + (31 - 255) * u) / 255)
    }
    static let gradient = LinearGradient(colors: [color(0), color(1)], startPoint: .leading, endPoint: .trailing)
}
