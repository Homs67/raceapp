//
//  SessionWeather.swift
//  raceApp
//
//  Conditions for a finished session from Apple Weather: the historical hour
//  nearest the middle of the drive, at the drive's start position. Fetched
//  once and saved into the manifest, so it costs one request per session.
//

import Foundation
import CoreLocation
import WeatherKit
import SessionKit

enum SessionWeather {

    static func fetch(for manifest: SessionManifest, at coordinate: CLLocationCoordinate2D) async throws
        -> SessionManifest.WeatherSnapshot? {
        let duration = manifest.highlights?.durationSeconds ?? 0
        let middle = manifest.startedAtUTC.addingTimeInterval(duration / 2)
        let hour = Calendar.current.dateInterval(of: .hour, for: middle)?.start ?? middle
        let forecast = try await WeatherService.shared.weather(
            for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            including: .hourly(startDate: hour.addingTimeInterval(-3600), endDate: hour.addingTimeInterval(7200)))
        guard let h = forecast.forecast.min(by: { abs($0.date.timeIntervalSince(middle)) < abs($1.date.timeIntervalSince(middle)) })
        else { return nil }
        return .init(temperatureC: h.temperature.converted(to: .celsius).value,
                     humidity: h.humidity,
                     windMps: h.wind.speed.converted(to: .metersPerSecond).value,
                     windFromDegrees: h.wind.direction.converted(to: .degrees).value,
                     symbolName: h.symbolName,
                     condition: h.condition.description,
                     observedAt: h.date,
                     source: "Apple Weather")
    }

    /// Conditions right now at a place (the track page's "Conditions now").
    static func current(at coordinate: CLLocationCoordinate2D) async throws -> SessionManifest.WeatherSnapshot {
        let w = try await WeatherService.shared.weather(
            for: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), including: .current)
        return .init(temperatureC: w.temperature.converted(to: .celsius).value,
                     humidity: w.humidity,
                     windMps: w.wind.speed.converted(to: .metersPerSecond).value,
                     windFromDegrees: w.wind.direction.converted(to: .degrees).value,
                     symbolName: w.symbolName,
                     condition: w.condition.description,
                     observedAt: w.date,
                     source: "Apple Weather")
    }

    /// Mark and legal link Apple requires wherever its weather data is shown.
    static func attribution() async -> WeatherAttribution? {
        try? await WeatherService.shared.attribution
    }

    /// Sessions already asked about this launch, so a failing request (offline,
    /// no entitlement) isn't repeated every time the screen opens.
    @MainActor static var attempted: Set<UUID> = []
}
