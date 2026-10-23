//
//  RaceBoxMemoryImporter.swift
//  raceApp
//
//  Turns a RaceBox memory dump into ordinary app sessions.
//
//  The device stores one continuous log rather than files. Separate drives
//  are recovered from the start/stop markers saved alongside the data, and
//  from gaps in the records' own GPS timestamps — a device that was simply
//  unplugged leaves no marker behind.
//
//  Each drive is written through SessionRecorder so an imported drive is
//  indistinguishable from a live one: same manifest, highlights, channel
//  files and export path. Records are written as they arrive, because a full
//  memory is hundreds of thousands of messages.
//

import Foundation
import SessionKit
import RaceBoxKit

actor RaceBoxMemoryImporter {

    /// Two records further apart than this belong to different drives even
    /// without a marker between them.
    private static let driveGapSeconds: TimeInterval = 120
    /// Below this a "drive" is a handful of stray records, not an outing.
    private static let minimumRecords = 25

    private let store: SessionStore
    private let car: SessionManifest.CarInfo?
    private let units: String?

    private var recorder: SessionRecorder?
    private var driveStart: Date?
    private var lastDate: Date?
    private var recordsInDrive = 0
    private(set) var driveCount = 0
    /// Why records didn't become drives, for the result screen.
    private(set) var recordsWithoutTime = 0
    private(set) var recordsBeforeStart = 0
    private(set) var shortDrivesDropped = 0
    private(set) var recordsAccepted = 0

    init(store: SessionStore, car: SessionManifest.CarInfo?, units: String?) {
        self.store = store
        self.car = car
        self.units = units
    }

    /// A start/stop marker from the device.
    func mark(running: Bool) async {
        await closeDrive()
        // Nothing to open on `running`: the next record starts the drive, so
        // a marker with no data after it leaves nothing behind.
    }

    func add(_ message: RaceBoxDataMessage) async {
        guard let date = message.timestamp else { recordsWithoutTime += 1; return }

        if let last = lastDate, date.timeIntervalSince(last) > Self.driveGapSeconds {
            await closeDrive()
        }
        if recorder == nil {
            await openDrive(at: date)
        }
        guard let recorder, let driveStart else { return }

        // Imported sessions get their own timeline starting at zero; the
        // manifest carries the real wall-clock start.
        let t = date.timeIntervalSince(driveStart)
        guard t >= 0 else { recordsBeforeStart += 1; return }
        recordsAccepted += 1

        await recorder.ingest(channel: .rbSatellites, value: Double(message.satellites), at: t)
        await recorder.ingest(channel: .rbFixStatus, value: Double(message.fixStatus.rawValue), at: t)
        await recorder.ingest(channel: .rbPdop, value: message.pdop, at: t)
        await recorder.ingest(channel: .rbGForceX, value: message.gForce.x, at: t)
        await recorder.ingest(channel: .rbGForceY, value: message.gForce.y, at: t)
        await recorder.ingest(channel: .rbGForceZ, value: message.gForce.z, at: t)
        await recorder.ingest(channel: .rbRollRate, value: message.rotationRate.x, at: t)
        await recorder.ingest(channel: .rbPitchRate, value: message.rotationRate.y, at: t)
        await recorder.ingest(channel: .rbYawRate, value: message.rotationRate.z, at: t)
        await recorder.ingest(channel: .rbWallTime, value: date.timeIntervalSince1970, at: t)

        // Position only once the receiver had a solution, matching the live path.
        if message.hasValidFix, message.coordinatesValid {
            await recorder.ingest(channel: .gpsLatitude, value: message.latitude, at: t)
            await recorder.ingest(channel: .gpsLongitude, value: message.longitude, at: t)
            await recorder.ingest(channel: .gpsSpeed, value: message.speedMps, at: t)
            await recorder.ingest(channel: .gpsAltitude, value: message.mslAltitude, at: t)
            await recorder.ingest(channel: .gpsHorizontalAccuracy, value: message.horizontalAccuracy, at: t)
            await recorder.ingest(channel: .gpsVerticalAccuracy, value: message.verticalAccuracy, at: t)
            await recorder.ingest(channel: .gpsSpeedAccuracy, value: message.speedAccuracyMps, at: t)
            await recorder.ingest(channel: .gpsWallTime, value: date.timeIntervalSince1970, at: t)
            if message.headingValid {
                await recorder.ingest(channel: .gpsCourse, value: message.headingDegrees, at: t)
            }
        }

        lastDate = date
        recordsInDrive += 1
    }

    /// Close any open drive and report how many were imported.
    func finish() async -> Int {
        await closeDrive()
        return driveCount
    }

    /// One line on where the records went.
    var accounting: String {
        var parts = ["\(recordsAccepted) written"]
        if recordsWithoutTime > 0 { parts.append("\(recordsWithoutTime) without a date") }
        if recordsBeforeStart > 0 { parts.append("\(recordsBeforeStart) out of order") }
        if shortDrivesDropped > 0 { parts.append("\(shortDrivesDropped) stub\(shortDrivesDropped == 1 ? "" : "s") under \(Self.minimumRecords) records dropped") }
        return parts.joined(separator: " · ")
    }

    private func openDrive(at date: Date) async {
        let recorder = SessionRecorder(store: store)
        do {
            _ = try await recorder.start(at: 0, utc: date, car: car, units: units,
                                         appVersion: Bundle.main.appVersion)
            self.recorder = recorder
            driveStart = date
            recordsInDrive = 0
        } catch {
            self.recorder = nil
        }
    }

    private func closeDrive() async {
        guard let recorder, let driveStart, let lastDate else { resetDrive(); return }
        let duration = lastDate.timeIntervalSince(driveStart)
        let worthKeeping = recordsInDrive >= Self.minimumRecords
        if let manifest = try? await recorder.stop(at: max(0, duration)) {
            if worthKeeping {
                driveCount += 1
            } else {
                // A few stray records either side of a marker aren't a drive.
                shortDrivesDropped += 1
                try? store.delete(manifest.id)
            }
        }
        resetDrive()
    }

    private func resetDrive() {
        recorder = nil
        driveStart = nil
        lastDate = nil
        recordsInDrive = 0
    }
}

private extension Bundle {
    var appVersion: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
