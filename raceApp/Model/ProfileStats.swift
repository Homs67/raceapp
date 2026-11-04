//
//  ProfileStats.swift
//  raceApp
//
//  Totals and personal records for the Profile tab, read off the session
//  manifests for a period (all time, this year, last 30 days). Every record
//  remembers the session it came from, so it can open it.
//

import Foundation
import SessionKit

enum StatsPeriod: String, CaseIterable, Identifiable {
    case allTime, year, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: return "All time"
        case .year: return String(Calendar.current.component(.year, from: Date()))
        case .month: return "30 days"
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .allTime: return true
        case .year: return calendar.component(.year, from: date) == calendar.component(.year, from: now)
        case .month: return date >= now.addingTimeInterval(-30 * 86_400)
        }
    }
}

struct ProfileStats {
    struct Record: Identifiable {
        enum Kind { case topSpeed, cornering, braking, maxRpm, longest, bestLap(trackId: String, name: String, autocross: Bool) }
        var kind: Kind
        var value: Double
        var session: UUID
        var isBestLap: Bool { if case .bestLap = kind { return true }; return false }
        var id: String {
            switch kind {
            case .topSpeed: return "speed"
            case .cornering: return "lat"
            case .braking: return "long"
            case .maxRpm: return "rpm"
            case .longest: return "longest"
            case .bestLap(let id, _, _): return "lap-\(id)"
            }
        }
    }

    var sessions = 0
    var seconds: TimeInterval = 0
    var meters: Double = 0
    var laps = 0
    var records: [Record] = []

    static func compute(_ manifests: [SessionManifest], period: StatsPeriod,
                        trackNames: [String: String], autocross: Set<String>) -> ProfileStats {
        var s = ProfileStats()
        var best: [String: Record] = [:]
        func keepMax(_ kind: Record.Kind, _ v: Double, _ m: SessionManifest) {
            guard v > 0 else { return }
            let r = Record(kind: kind, value: v, session: m.id)
            if let i = s.records.firstIndex(where: { $0.id == r.id }) {
                if v > s.records[i].value { s.records[i] = r }
            } else {
                s.records.append(r)
            }
        }
        for m in manifests where period.contains(m.startedAtUTC) {
            s.sessions += 1
            let h = m.highlights
            s.seconds += h?.durationSeconds ?? 0
            s.meters += h?.distanceMeters ?? 0
            if let h {
                keepMax(.topSpeed, h.maxSpeedMps, m)
                keepMax(.cornering, h.peakLatG, m)
                keepMax(.braking, h.peakLongG, m)
                keepMax(.maxRpm, h.maxRpm, m)
                keepMax(.longest, h.durationSeconds, m)
            }
            if let ref = m.track, !ref.id.isEmpty {
                for run in ref.runs where run.kind != .dnf {
                    guard let d = run.duration else { continue }
                    s.laps += 1
                    if d < best[ref.id]?.value ?? .infinity {
                        best[ref.id] = Record(kind: .bestLap(trackId: ref.id, name: trackNames[ref.id] ?? ref.nameSnapshot,
                                                             autocross: autocross.contains(ref.id)),
                                              value: d, session: m.id)
                    }
                }
            }
        }
        let order: [String] = ["speed", "lat", "long", "rpm", "longest"]
        s.records.sort { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
        s.records += best.values.sorted { $0.value < $1.value }
        return s
    }
}
