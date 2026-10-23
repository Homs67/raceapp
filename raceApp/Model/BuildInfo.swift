//
//  BuildInfo.swift
//  raceApp
//
//  Which build produced a session. The "Stamp build info" build phase writes
//  the git commit (with a trailing "+" when the tree had uncommitted changes)
//  and the build time into Info.plist; everything that leaves the phone —
//  session manifests, diagnostics, Settings — quotes it, so a drive can be
//  matched to the exact code that recorded it.
//

import Foundation

enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    static var commit: String? {
        Bundle.main.infoDictionary?["RaceAppGitCommit"] as? String
    }
    static var builtAt: String? {
        Bundle.main.infoDictionary?["RaceAppBuildDate"] as? String
    }

    /// "1.0 (1) · 135386e · built 2026-10-23T20:05:11Z"
    static var description: String {
        var parts = ["\(version) (\(buildNumber))"]
        if let commit { parts.append(commit) }
        if let builtAt { parts.append("built \(builtAt)") }
        return parts.joined(separator: " · ")
    }
}
