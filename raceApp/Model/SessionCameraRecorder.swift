//
//  SessionCameraRecorder.swift
//  raceApp
//
//  Opt-in session camera capture: MultiCam front+rear when available,
//  otherwise rear-only. Clips land in the session videos/ folder stamped
//  with phone wall-clock start for auto-sync to the session timeline.
//

@preconcurrency import AVFoundation
import Foundation
import SessionKit
import UIKit

@MainActor
@Observable
final class SessionCameraRecorder: NSObject {

    /// Dashboard control: N/A (no access / no hardware), OFF, or ON (green).
    enum UIStatus: Equatable {
        case unavailable
        case off
        case on
    }

    private(set) var uiStatus: UIStatus = .off
    private(set) var isCapturing = false
    private(set) var usesMultiCam = false
    private(set) var lastError: String?
    /// Live preview layers while capturing (rear fills; front is optional PiP).
    private(set) var rearPreviewLayer: AVCaptureVideoPreviewLayer?
    private(set) var frontPreviewLayer: AVCaptureVideoPreviewLayer?

    private var captureSession: AVCaptureSession?
    private var rearOutput: AVCaptureMovieFileOutput?
    private var frontOutput: AVCaptureMovieFileOutput?
    private var videosDirectory: URL?
    private var activeSessionId: UUID?
    private var openClips: [ObjectIdentifier: OpenClip] = [:]
    private var stopContinuations: [CheckedContinuation<[VideoAsset], Never>] = []
    private var pendingAssets: [VideoAsset] = []
    private var expectedFinishes = 0

    private struct OpenClip {
        let role: VideoAsset.Role
        let fileName: String
        let url: URL
        let wallClockStart: Date
    }

    override init() {
        super.init()
        refreshAuthorizationStatus()
    }

    // MARK: - Authorization / status

    func refreshAuthorizationStatus() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        let hasRear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        switch auth {
        case .denied, .restricted:
            uiStatus = .unavailable
        case .notDetermined:
            uiStatus = hasRear ? .off : .unavailable
        case .authorized:
            if !hasRear {
                uiStatus = .unavailable
            } else if isCapturing {
                uiStatus = .on
            } else {
                uiStatus = .off
            }
        @unknown default:
            uiStatus = .unavailable
        }
    }

    @discardableResult
    func requestAccessIfNeeded() async -> Bool {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        switch auth {
        case .authorized:
            refreshAuthorizationStatus()
            return uiStatus != .unavailable
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            // Mic is optional; request so writers can mux audio when available.
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshAuthorizationStatus()
            return granted && uiStatus != .unavailable
        case .denied, .restricted:
            refreshAuthorizationStatus()
            return false
        @unknown default:
            refreshAuthorizationStatus()
            return false
        }
    }

    // MARK: - Toggle / lifecycle

    /// Toggle capture while a telemetry session is active.
    func toggle(sessionId: UUID, sessionDirectory: URL) async -> [VideoAsset] {
        if isCapturing {
            return await stopCapture()
        }
        guard await requestAccessIfNeeded() else { return [] }
        guard uiStatus != .unavailable else { return [] }
        // Prompt once up-front so Photos backup doesn't interrupt session stop.
        _ = await VideoLibrary.requestPhotoLibraryAddAccess()
        do {
            try await startCapture(sessionId: sessionId, sessionDirectory: sessionDirectory)
            return []
        } catch {
            lastError = error.localizedDescription
            uiStatus = .off
            isCapturing = false
            return []
        }
    }

    /// Always stop camera when the driving session ends.
    func stopForSessionEnd() async -> [VideoAsset] {
        await stopCapture()
    }

    private func startCapture(sessionId: UUID, sessionDirectory: URL) async throws {
        guard !isCapturing else { return }
        lastError = nil
        activeSessionId = sessionId
        let videos = VideoLibrary.videosDirectory(sessionDirectory: sessionDirectory)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        videosDirectory = videos

        tearDownSession()
        let multi = AVCaptureMultiCamSession.isMultiCamSupported
        if multi, let configured = try? makeMultiCamSession() {
            captureSession = configured.session
            rearOutput = configured.rear
            frontOutput = configured.front
            rearPreviewLayer = configured.rearPreview
            frontPreviewLayer = configured.frontPreview
            usesMultiCam = true
        } else {
            let configured = try makeRearOnlySession()
            captureSession = configured.session
            rearOutput = configured.rear
            frontOutput = nil
            rearPreviewLayer = configured.rearPreview
            frontPreviewLayer = nil
            usesMultiCam = false
        }
        let session = captureSession!
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                cont.resume()
            }
        }

        try beginWritingFiles()
        // MultiCam + MovieFileOutput can fail silently on some devices (preview
        // works, files never open). Fall back to rear-only recording if needed.
        try await Task.sleep(for: .milliseconds(250))
        if rearOutput?.isRecording != true {
            lastError = "Dual capture failed — retrying rear-only"
            tearDownSession()
            let configured = try makeRearOnlySession()
            captureSession = configured.session
            rearOutput = configured.rear
            frontOutput = nil
            rearPreviewLayer = configured.rearPreview
            frontPreviewLayer = nil
            usesMultiCam = false
            let session = captureSession!
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                    cont.resume()
                }
            }
            try beginWritingFiles()
            try await Task.sleep(for: .milliseconds(250))
            if rearOutput?.isRecording != true {
                tearDownSession()
                isCapturing = false
                uiStatus = .off
                throw CameraError.notConfigured
            }
        }
        isCapturing = true
        uiStatus = .on
    }

    private func stopCapture() async -> [VideoAsset] {
        guard isCapturing else {
            refreshAuthorizationStatus()
            return []
        }
        let assets: [VideoAsset] = await withCheckedContinuation { cont in
            stopContinuations.append(cont)
            expectedFinishes = openClips.count
            pendingAssets = []
            if expectedFinishes == 0 {
                finishStopLocked()
                return
            }
            rearOutput?.stopRecording()
            frontOutput?.stopRecording()
        }
        isCapturing = false
        tearDownSession()
        activeSessionId = nil
        videosDirectory = nil
        refreshAuthorizationStatus()
        return assets
    }

    private func finishStopLocked() {
        let assets = pendingAssets
        pendingAssets = []
        expectedFinishes = 0
        openClips.removeAll()
        let waiters = stopContinuations
        stopContinuations = []
        for cont in waiters { cont.resume(returning: assets) }
    }

    private func beginWritingFiles() throws {
        guard let videosDirectory else {
            throw CameraError.notConfigured
        }
        openClips.removeAll()
        applyCaptureOrientation()
        let stamp = Int(Date().timeIntervalSince1970)
        if let rear = rearOutput {
            let fileName = "rear-\(stamp).mp4"
            let url = videosDirectory.appendingPathComponent(fileName)
            let wall = Date()
            openClips[ObjectIdentifier(rear)] = OpenClip(
                role: .rear, fileName: fileName, url: url, wallClockStart: wall)
            rear.startRecording(to: url, recordingDelegate: self)
        }
        if let front = frontOutput {
            let fileName = "front-\(stamp).mp4"
            let url = videosDirectory.appendingPathComponent(fileName)
            let wall = Date()
            openClips[ObjectIdentifier(front)] = OpenClip(
                role: .front, fileName: fileName, url: url, wallClockStart: wall)
            front.startRecording(to: url, recordingDelegate: self)
        }
        if openClips.isEmpty {
            throw CameraError.notConfigured
        }
    }

    /// Stamp clips using each camera's horizon-level capture angle (front ≠ rear).
    private func applyCaptureOrientation() {
        func apply(to output: AVCaptureMovieFileOutput?, preview: AVCaptureVideoPreviewLayer?) {
            guard let output else { return }
            for connection in output.connections {
                let device = connection.inputPorts
                    .compactMap { $0.input as? AVCaptureDeviceInput }
                    .map(\.device)
                    .first
                let angle: CGFloat
                if let device {
                    let coordinator = AVCaptureDevice.RotationCoordinator(
                        device: device, previewLayer: preview)
                    angle = coordinator.videoRotationAngleForHorizonLevelCapture
                } else {
                    angle = 90
                }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                // Keep recorded front footage mirrored consistently with preview.
                if device?.position == .front, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
        apply(to: rearOutput, preview: rearPreviewLayer)
        apply(to: frontOutput, preview: frontPreviewLayer)
    }

    // MARK: - Session setup

    private struct ConfiguredOutputs {
        let session: AVCaptureSession
        let rear: AVCaptureMovieFileOutput
        let front: AVCaptureMovieFileOutput?
        let rearPreview: AVCaptureVideoPreviewLayer
        let frontPreview: AVCaptureVideoPreviewLayer?
    }

    private func makeMultiCamSession() throws -> ConfiguredOutputs {
        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let rearDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back),
              let frontDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front)
        else {
            throw CameraError.deviceUnavailable
        }

        let rearInput = try AVCaptureDeviceInput(device: rearDevice)
        let frontInput = try AVCaptureDeviceInput(device: frontDevice)
        guard session.canAddInput(rearInput), session.canAddInput(frontInput) else {
            throw CameraError.deviceUnavailable
        }
        session.addInputWithNoConnections(rearInput)
        session.addInputWithNoConnections(frontInput)

        let rearOut = AVCaptureMovieFileOutput()
        let frontOut = AVCaptureMovieFileOutput()
        guard session.canAddOutput(rearOut), session.canAddOutput(frontOut) else {
            throw CameraError.deviceUnavailable
        }
        session.addOutputWithNoConnections(rearOut)
        session.addOutputWithNoConnections(frontOut)

        let rearPreview = AVCaptureVideoPreviewLayer()
        rearPreview.setSessionWithNoConnection(session)
        rearPreview.videoGravity = .resizeAspectFill
        let frontPreview = AVCaptureVideoPreviewLayer()
        frontPreview.setSessionWithNoConnection(session)
        frontPreview.videoGravity = .resizeAspectFill

        if let rearPort = rearInput.ports(
            for: .video, sourceDeviceType: rearDevice.deviceType,
            sourceDevicePosition: rearDevice.position).first {
            let fileConn = AVCaptureConnection(inputPorts: [rearPort], output: rearOut)
            if session.canAddConnection(fileConn) { session.addConnection(fileConn) }
            let previewConn = AVCaptureConnection(inputPort: rearPort, videoPreviewLayer: rearPreview)
            if session.canAddConnection(previewConn) { session.addConnection(previewConn) }
        }
        if let frontPort = frontInput.ports(
            for: .video, sourceDeviceType: frontDevice.deviceType,
            sourceDevicePosition: frontDevice.position).first {
            let fileConn = AVCaptureConnection(inputPorts: [frontPort], output: frontOut)
            if session.canAddConnection(fileConn) { session.addConnection(fileConn) }
            let previewConn = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontPreview)
            if session.canAddConnection(previewConn) {
                session.addConnection(previewConn)
                if previewConn.isVideoMirroringSupported {
                    previewConn.automaticallyAdjustsVideoMirroring = false
                    previewConn.isVideoMirrored = true
                }
            }
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        return ConfiguredOutputs(
            session: session, rear: rearOut, front: frontOut,
            rearPreview: rearPreview, frontPreview: frontPreview)
    }

    private func makeRearOnlySession() throws -> ConfiguredOutputs {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let rearDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back)
        else {
            throw CameraError.deviceUnavailable
        }
        let rearInput = try AVCaptureDeviceInput(device: rearDevice)
        guard session.canAddInput(rearInput) else { throw CameraError.deviceUnavailable }
        session.addInput(rearInput)

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let rearOut = AVCaptureMovieFileOutput()
        guard session.canAddOutput(rearOut) else { throw CameraError.deviceUnavailable }
        session.addOutput(rearOut)

        let rearPreview = AVCaptureVideoPreviewLayer(session: session)
        rearPreview.videoGravity = .resizeAspectFill

        return ConfiguredOutputs(
            session: session, rear: rearOut, front: nil,
            rearPreview: rearPreview, frontPreview: nil)
    }

    private func tearDownSession() {
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        rearPreviewLayer?.removeFromSuperlayer()
        frontPreviewLayer?.removeFromSuperlayer()
        rearPreviewLayer = nil
        frontPreviewLayer = nil
        captureSession = nil
        rearOutput = nil
        frontOutput = nil
        usesMultiCam = false
    }

    private enum CameraError: LocalizedError {
        case deviceUnavailable
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "Camera unavailable"
            case .notConfigured: return "Camera not configured"
            }
        }
    }
}

// MARK: - File output delegate

extension SessionCameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.handleFinished(output: output, url: outputFileURL, error: error)
        }
    }

    private func handleFinished(output: AVCaptureFileOutput, url: URL, error: Error?) {
        let key = ObjectIdentifier(output)
        guard let clip = openClips.removeValue(forKey: key) else { return }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        // AVFoundation often returns a non-nil error even for a usable stopped clip
        // (e.g. session ending). Keep the file whenever it has real bytes.
        let usable = size > 10_000
        if let error, !usable {
            lastError = error.localizedDescription
            try? FileManager.default.removeItem(at: url)
        } else {
            if error != nil, usable {
                lastError = nil // recoverable finish warning — clip kept
            }
            let duration = max(0.1, Date().timeIntervalSince(clip.wallClockStart))
            pendingAssets.append(VideoAsset(
                fileName: clip.fileName,
                wallClockStart: clip.wallClockStart,
                duration: duration,
                fileSizeBytes: size,
                hasEmbeddedDate: true,
                role: clip.role
            ))
            // Gallery backup so clips can be re-imported if session attach fails.
            let backupURL = url
            Task { await VideoLibrary.saveCopyToPhotoLibrary(backupURL) }
        }
        if !stopContinuations.isEmpty {
            expectedFinishes = max(0, expectedFinishes - 1)
            if expectedFinishes == 0 {
                finishStopLocked()
            }
        }
    }

    /// Pick up any session MP4s that finished on disk but never made it into the manifest.
    func recoverOrphanClips(sessionDirectory: URL) -> [VideoAsset] {
        let directory = VideoLibrary.videosDirectory(sessionDirectory: sessionDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        var orphans: [VideoAsset] = []
        for url in files where url.pathExtension.lowercased() == "mp4" {
            let name = url.lastPathComponent
            let role: VideoAsset.Role
            if name.hasPrefix("rear-") { role = .rear }
            else if name.hasPrefix("front-") { role = .front }
            else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 10_000 else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            // Duration unknown without async load — use file age as a lower bound; review loads real duration.
            let duration = max(0.1, Date().timeIntervalSince(created))
            orphans.append(VideoAsset(
                fileName: name,
                wallClockStart: created,
                duration: duration,
                fileSizeBytes: size,
                hasEmbeddedDate: true,
                role: role
            ))
        }
        return orphans
    }
}
