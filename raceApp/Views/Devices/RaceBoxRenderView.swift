//
//  RaceBoxRenderView.swift
//  raceApp
//
//  The live case on the device page: idles on a slow turntable, drag to spin.
//

import SwiftUI
import SceneKit

struct RaceBoxRenderView: UIViewRepresentable {

    var pose: RaceBoxDevicePose = .angled
    /// Seconds per revolution while idle; nil stands still.
    var turntable: Double? = 28
    /// The page tells us when it is really on screen. SwiftUI does not call
    /// `onDisappear` for a view covered by a sheet, so the view would
    /// otherwise keep rendering behind one.
    var isVisible = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = PausingSCNView()
        view.scene = RaceBoxDeviceScene.make(pose: pose)
        view.pointOfView = view.scene?.rootNode
            .childNode(withName: RaceBoxDeviceScene.orbitYawNodeName, recursively: true)?
            .childNode(withName: RaceBoxDeviceScene.orbitPitchNodeName, recursively: true)?
            .childNode(withName: RaceBoxDeviceScene.cameraNodeName, recursively: true)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // Not the lever people reach for: this only forces redraws when
        // nothing changed. `isPlaying` is what advances the turntable.
        view.rendersContinuously = false

        let root = view.scene?.rootNode
        context.coordinator.spin = root?.childNode(withName: RaceBoxDeviceScene.spinNodeName, recursively: false)
        context.coordinator.orbitYaw = root?.childNode(withName: RaceBoxDeviceScene.orbitYawNodeName, recursively: false)
        context.coordinator.orbitPitch = context.coordinator.orbitYaw?
            .childNode(withName: RaceBoxDeviceScene.orbitPitchNodeName, recursively: false)
        context.coordinator.view = view
        context.coordinator.cameraNode = view.pointOfView

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        context.coordinator.apply(pose: pose, animated: false)
        context.coordinator.setTurntable(turntable)
        context.coordinator.setRunning(isVisible && turntable != nil)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.apply(pose: pose, animated: true)
        context.coordinator.setTurntable(turntable)
        context.coordinator.setRunning(isVisible && turntable != nil)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.setRunning(false)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: SCNView?
        var spin: SCNNode?
        var orbitYaw: SCNNode?
        var orbitPitch: SCNNode?
        var cameraNode: SCNNode?

        private var pose: RaceBoxDevicePose?
        private var seconds: Double?
        private var running = false
        private var startYaw: Float = 0

        func apply(pose next: RaceBoxDevicePose, animated: Bool) {
            guard pose != next else { return }
            pose = next
            guard let orbitYaw, let orbitPitch else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.7 : 0
            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
            orbitYaw.eulerAngles = SCNVector3(0, next.yaw, 0)
            orbitPitch.eulerAngles = SCNVector3(-next.pitch, 0, 0)
            cameraNode?.position = SCNVector3(0, 0, RaceBoxDeviceScene.cameraDistance(for: next))
            SCNTransaction.commit()
            // The near-top pose is a still life; nothing to keep rendering for.
            if animated { setRunning(running) }
        }

        func setTurntable(_ next: Double?) {
            guard seconds != next else { return }
            seconds = next
            spin?.removeAllActions()
            guard let next else { return }
            spin?.runAction(.repeatForever(
                .rotateBy(x: 0, y: .pi * 2, z: 0, duration: next)))
        }

        func setRunning(_ next: Bool) {
            running = next
            // A static pose costs nothing to hold, so stop the loop.
            view?.isPlaying = next && seconds != nil && pose == .angled
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let spin, let view = g.view else { return }
            let t = g.translation(in: view)
            switch g.state {
            case .began:
                spin.removeAllActions()
                startYaw = spin.presentation.eulerAngles.y
                spin.eulerAngles = spin.presentation.eulerAngles
                self.view?.preferredFramesPerSecond = 60
                self.view?.isPlaying = true
            case .changed:
                spin.eulerAngles = SCNVector3(0, startYaw + Float(t.x) * 0.01, 0)
            case .ended, .cancelled:
                // Carry the flick, then pick the turntable back up where it
                // left off — there is no front face to settle onto.
                let yaw = spin.eulerAngles.y
                let projected = yaw + Float(g.velocity(in: view).x) * 0.01 * 0.45
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.8
                SCNTransaction.animationTimingFunction =
                    CAMediaTimingFunction(controlPoints: 0.1, 0.8, 0.2, 1)
                SCNTransaction.completionBlock = { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.view?.preferredFramesPerSecond = 30
                        let seconds = self.seconds
                        self.seconds = nil
                        self.setTurntable(seconds)
                        self.setRunning(self.running)
                    }
                }
                spin.eulerAngles = SCNVector3(0, projected, 0)
                SCNTransaction.commit()
            default:
                break
            }
        }

        /// Let a vertical drag fall through to the sheet's dismiss gesture —
        /// Settings is a sheet, and a page inside it must stay dismissable.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let v = pan.velocity(in: view)
            return abs(v.x) > abs(v.y)
        }
    }
}

/// Stops rendering the moment it leaves the window, which `onDisappear` alone
/// does not guarantee.
private final class PausingSCNView: SCNView {
    private var wasPlaying = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            wasPlaying = isPlaying
            isPlaying = false
        } else if wasPlaying {
            isPlaying = true
        }
    }
}
