//
//  Garage.swift
//  raceApp
//
//  The driver's cars. One is the car being driven: new sessions are recorded
//  against it (it is written through to `PreferredCar`, which the recorder
//  already reads). Each car can carry a photo with its background removed
//  on-device (Vision), shown as a cut-out on the Profile tab.
//
//  Stored as <AppSupport>/LiveData/garage/garage.json plus one PNG per photo.
//

import Foundation
import UIKit
import Vision
import CoreImage
import SessionKit

struct GarageCar: Codable, Identifiable, Hashable {
    var id = UUID()
    var make: String
    var model: String
    var year: Int?
    /// "Machine Grey".
    var color: String?
    /// File name in the garage folder; nil until a photo is added.
    var photoFile: String?
    /// The bundled stand-in photo, for the car migrated from "My car".
    var bundledPhoto: String?

    var title: String { model }
    var subtitle: String {
        [year.map(String.init), color].compactMap { $0 }.joined(separator: " · ")
    }

    var preferred: PreferredCar {
        PreferredCar(id: "garage-\(id.uuidString)", make: make, model: model, year: year)
    }

    /// Whether a session's recorded car is this one.
    func matches(_ info: SessionManifest.CarInfo?) -> Bool {
        guard let info, info.make?.caseInsensitiveCompare(make) == .orderedSame,
              let m = info.model else { return false }
        return m.localizedCaseInsensitiveContains(model)
    }
}

@MainActor @Observable
final class Garage {
    private(set) var cars: [GarageCar] = []
    private(set) var activeId: UUID?
    /// Bumped when a photo changes so views reload it.
    private(set) var photoVersion = 0

    private struct Stored: Codable {
        var cars: [GarageCar]
        var activeId: UUID?
    }

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveData/garage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var file: URL { folder.appendingPathComponent("garage.json") }

    init() {
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            cars = stored.cars
            activeId = stored.activeId
        } else if let preferred = PreferredCar.load() {
            // First run with a garage: the car chosen in Settings moves in.
            var car = GarageCar(make: preferred.make, model: preferred.model, year: preferred.year)
            if preferred.model.localizedCaseInsensitiveContains("MX-5") { car.bundledPhoto = "CarMX5" }
            cars = [car]
            activeId = car.id
            persist()
        }
    }

    var active: GarageCar? { cars.first { $0.id == activeId } ?? cars.first }

    func setActive(_ car: GarageCar) {
        activeId = car.id
        car.preferred.save()
        persist()
    }

    func add(_ car: GarageCar, photo: UIImage?) async {
        cars.append(car)
        if cars.count == 1 { setActive(car) }
        persist()
        if let photo { await setPhoto(photo, for: car.id) }
    }

    func update(_ car: GarageCar) {
        guard let i = cars.firstIndex(where: { $0.id == car.id }) else { return }
        cars[i] = car
        if car.id == activeId { car.preferred.save() }
        persist()
    }

    func remove(_ car: GarageCar) {
        if let f = car.photoFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
        cars.removeAll { $0.id == car.id }
        if activeId == car.id {
            activeId = cars.first?.id
            if let next = cars.first { next.preferred.save() } else { PreferredCar.clear() }
        }
        persist()
    }

    /// Cut the car out of its background and keep it as the car's photo.
    func setPhoto(_ image: UIImage, for id: UUID) async {
        let cutout = await Task.detached(priority: .userInitiated) { Self.cutOut(image) ?? image }.value
        guard let png = cutout.pngData(), let i = cars.firstIndex(where: { $0.id == id }) else { return }
        let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
        try? png.write(to: folder.appendingPathComponent(name), options: .atomic)
        if let old = cars[i].photoFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        cars[i].photoFile = name
        cars[i].bundledPhoto = nil
        photoVersion += 1
        persist()
    }

    func photo(for car: GarageCar) -> UIImage? {
        if let f = car.photoFile, let img = UIImage(contentsOfFile: folder.appendingPathComponent(f).path) { return img }
        if let b = car.bundledPhoto { return UIImage(named: b) }
        return nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Stored(cars: cars, activeId: activeId)) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The photo's subject on a transparent background, cropped to it.
    nonisolated static func cutOut(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg).oriented(CGImagePropertyOrientation(image.imageOrientation))
        let handler = VNImageRequestHandler(ciImage: input)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                         croppedToInstancesExtent: true) else { return nil }
        let out = CIImage(cvPixelBuffer: buffer)
        guard let rendered = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}

private extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
