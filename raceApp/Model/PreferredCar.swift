//
//  PreferredCar.swift
//  raceApp
//
//  User-selected car preference for Settings → My car.
//

import Foundation
import SessionKit

struct PreferredCar: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var make: String
    var model: String
    var year: Int?

    var displayName: String {
        if let year {
            return "\(year) \(make) \(model)"
        }
        return "\(make) \(model)".trimmingCharacters(in: .whitespaces)
    }

    var asCarInfo: SessionManifest.CarInfo {
        .init(make: make, model: year.map { "\($0) \(model)" } ?? model)
    }

    static let presets: [PreferredCar] = [
        .init(id: "mazda-mx5-nd2", make: "Mazda", model: "MX-5 ND2", year: 2019),
        .init(id: "toyota-gr86", make: "Toyota", model: "GR86", year: 2023),
        .init(id: "subaru-brz", make: "Subaru", model: "BRZ", year: 2023),
        .init(id: "porsche-911-gt3", make: "Porsche", model: "911 GT3", year: 2022),
        .init(id: "bmw-m2", make: "BMW", model: "M2", year: 2023),
    ]

    static let customId = "custom"

    static func load() -> PreferredCar? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let car = try? JSONDecoder().decode(PreferredCar.self, from: data) else {
            return nil
        }
        return car
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static let storageKey = "preferredCar"
}

enum DashboardFaces {
    static let names = [
        "Primary",
        "G-Force",
        "Track Map",
        "Lap Timing",
    ]

    static func name(for index: Int) -> String {
        guard names.indices.contains(index) else { return names[0] }
        return names[index]
    }
}
