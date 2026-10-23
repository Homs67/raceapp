//
//  CloudDriveSync.swift
//  raceApp
//
//  Mirrors every finished session's CSV + JSON into the app's iCloud Drive
//  folder (Files → iCloud Drive → raceApp → Drives). iCloud carries them to
//  any Mac signed into the same Apple ID, which is how a drive gets analysed
//  without a share sheet. The raw dump is deliberately left out: it is ten
//  times the size and nothing downstream needs it.
//

import Foundation
import SessionKit

@MainActor @Observable
final class CloudDriveSync {

    private enum Keys {
        static let enabled = "cloudDrive.export"
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// Last outcome, for Settings: "Saved LiveData-… · 14:32" or why not.
    private(set) var status: String?
    private(set) var isWorking = false

    static let folderName = "Drives"

    /// The container is resolved off the main thread: the first call after
    /// launch can block while iCloud sets the directory up.
    nonisolated static func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    func sync(manifest: SessionManifest, sessionDirectory: URL) {
        guard isEnabled else { return }
        isWorking = true
        status = "Saving to iCloud Drive…"
        let base = SessionExporter.baseName(for: manifest)
        Task.detached(priority: .utility) { [weak self] in
            let outcome: String
            if let folder = Self.containerURL() {
                do {
                    _ = try SessionExporter.exportLightFiles(manifest: manifest,
                                                             sessionDirectory: sessionDirectory,
                                                             to: folder)
                    outcome = "Saved \(base) · \(Self.clock.string(from: Date()))"
                } catch {
                    outcome = "Couldn't save \(base): \(error.localizedDescription)"
                }
            } else {
                outcome = "iCloud Drive unavailable — sign in to iCloud and enable iCloud Drive for raceApp"
            }
            await MainActor.run {
                self?.status = outcome
                self?.isWorking = false
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
