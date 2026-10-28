//
//  VideoImporter.swift
//  raceApp
//
//  Adds and removes a session's video clips: Photos picks and Files URLs are
//  copied into the session's videos/ folder and placed by their recording time.
//  Shared by the session page and the map's "+ Camera".
//

import Foundation
import PhotosUI
import SwiftUI
import SessionKit

@MainActor
enum VideoImporter {
    /// Imports Photos picks one by one; returns the updated manifest.
    @discardableResult
    static func importPicked(_ items: [PhotosPickerItem], sessionId: UUID, model: AppModel,
                             progress: (Int, Int) -> Void = { _, _ in }) async -> SessionManifest? {
        var latest: SessionManifest?
        for (i, item) in items.enumerated() {
            progress(i + 1, items.count)
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                latest = await importOne(from: movie.url, sessionId: sessionId, model: model) ?? latest
                try? FileManager.default.removeItem(at: movie.url)
            }
        }
        return latest
    }

    /// Imports files chosen in Files (security-scoped URLs).
    @discardableResult
    static func importFiles(_ urls: [URL], sessionId: UUID, model: AppModel,
                            progress: (Int, Int) -> Void = { _, _ in }) async -> SessionManifest? {
        var latest: SessionManifest?
        for (i, url) in urls.enumerated() {
            progress(i + 1, urls.count)
            let scoped = url.startAccessingSecurityScopedResource()
            latest = await importOne(from: url, sessionId: sessionId, model: model) ?? latest
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return latest
    }

    static func importOne(from url: URL, sessionId: UUID, model: AppModel) async -> SessionManifest? {
        guard var manifest = try? model.store.manifest(for: sessionId) else { return nil }
        let directory = model.store.directory(for: sessionId)
        guard let asset = try? await VideoLibrary.importVideo(
            from: url, sessionDirectory: directory, fallbackStart: manifest.startedAtUTC) else { return nil }
        manifest.videos = (manifest.videos ?? []) + [asset]
        try? model.store.save(manifest)
        model.recording.sessionUpdated()
        return manifest
    }

    /// Removes clips (all of them when `ids` is nil); clearing the last one
    /// also drops the alignment.
    @discardableResult
    static func remove(_ ids: Set<UUID>? = nil, sessionId: UUID, model: AppModel) -> SessionManifest? {
        guard var manifest = try? model.store.manifest(for: sessionId) else { return nil }
        let directory = model.store.directory(for: sessionId)
        let doomed = (manifest.videos ?? []).filter { ids?.contains($0.id) ?? true }
        doomed.forEach { VideoLibrary.deleteFile(for: $0, sessionDirectory: directory) }
        manifest.videos = (manifest.videos ?? []).filter { a in !doomed.contains { $0.id == a.id } }
        if manifest.videos?.isEmpty ?? true {
            manifest.videos = nil
            manifest.videoSync = nil
        }
        try? model.store.save(manifest)
        model.recording.sessionUpdated()
        return manifest
    }

    /// "Swap cameras": every Front clip becomes Rear and vice versa.
    @discardableResult
    static func swapCameras(sessionId: UUID, model: AppModel) -> SessionManifest? {
        guard var manifest = try? model.store.manifest(for: sessionId) else { return nil }
        manifest.videos = manifest.videos?.map { var a = $0; a.camera = $0.slot == .front ? .rear : .front; return a }
        if var sync = manifest.videoSync {
            (sync.frontOffset, sync.rearOffset) = (sync.rearOffset, sync.frontOffset)
            manifest.videoSync = sync
        }
        try? model.store.save(manifest)
        model.recording.sessionUpdated()
        return manifest
    }
}
