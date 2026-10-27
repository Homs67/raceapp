//
//  CourseMatcher.swift
//  SessionKit
//
//  Which track was this session driven on? Nobody picks one before a run, so
//  the answer comes from the GPS afterwards: time the trace against every
//  nearby track and keep the one it actually completed runs or laps on.
//  Two autocross courses in the same parking lot both sit "nearby"; the one
//  whose gates the car really went through, in the right direction, wins —
//  and if both fit, the course built closest to the session's date.
//

import Foundation

public enum CourseMatcher {

    public struct Candidate: Sendable {
        public let id: String
        public let layout: CourseLayout
        public let createdAt: Date?
        public init(id: String, layout: CourseLayout, createdAt: Date?) {
            self.id = id
            self.layout = layout
            self.createdAt = createdAt
        }
    }

    public struct Match: Equatable, Sendable {
        public let id: String
        public let runs: [TimedRun]
    }

    /// - Parameter maxDistanceMeters: a track is only timed if the trace came
    ///   this close to its start gate.
    public static func best(_ candidates: [Candidate], lat: [ChannelSample], lon: [ChannelSample],
                            sessionDate: Date, maxDistanceMeters: Double = 1000) -> Match? {
        var winner: (match: Match, completed: Int, age: TimeInterval)?
        for c in candidates where passesNear(c.layout.start, lat: lat, lon: lon, within: maxDistanceMeters) {
            let runs = CourseTiming.runs(lat: lat, lon: lon, layout: c.layout)
            let completed = runs.filter { $0.kind != .dnf }.count
            guard completed > 0 else { continue }
            let age = c.createdAt.map { abs($0.timeIntervalSince(sessionDate)) } ?? .greatestFiniteMagnitude
            if let w = winner, (w.completed, -w.age) >= (completed, -age) { continue }
            winner = (Match(id: c.id, runs: runs), completed, age)
        }
        return winner?.match
    }

    static func passesNear(_ gate: TimingGate, lat: [ChannelSample], lon: [ChannelSample],
                           within meters: Double) -> Bool {
        let mLat = 110_540.0, mLon = 111_320.0 * cos(gate.lat * .pi / 180)
        let n = min(lat.count, lon.count)
        var i = 0
        while i < n {
            let dy = (lat[i].value - gate.lat) * mLat, dx = (lon[i].value - gate.lon) * mLon
            if dx * dx + dy * dy <= meters * meters { return true }
            i += 10
        }
        return false
    }
}
