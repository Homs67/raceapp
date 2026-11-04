//
//  EmblemView.swift
//  raceApp
//
//  The live, spinnable emblem (Apple Fitness awards style): drag to turn it,
//  let go and it keeps spinning, then settles on its front or its back.
//  Thumbnails in the grid are still images (`EmblemThumbnail`) — a live
//  SceneKit view per emblem would be too heavy for a list.
//

import SwiftUI
import SceneKit

struct EmblemView: UIViewRepresentable {
    let content: EmblemContent
    /// Spin in from the side when shown (the unlock pop-up does a bigger one).
    var introTurns: Float = 1

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = EmblemScene.make(content)
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        let medal = view.scene?.rootNode.childNode(withName: "medal", recursively: false)
        context.coordinator.medal = medal
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.pan(_:))))
        context.coordinator.intro(turns: introTurns)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        var medal: SCNNode?
        /// Playground bookkeeping: which build is showing, flips requested.
        var builtVersion = -1
        var flipCount = 0

        /// Turn half a turn to the other face.
        func flip() {
            guard let medal else { return }
            let target = ((medal.presentation.eulerAngles.y / .pi).rounded() + 1) * .pi
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.8
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
            medal.eulerAngles = SCNVector3(0, target, 0)
            SCNTransaction.commit()
            yaw = target
        }
        private var yaw: Float = 0
        private var startYaw: Float = 0

        func intro(turns: Float) {
            guard let medal else { return }
            medal.eulerAngles = SCNVector3(0, -.pi * 2 * turns - 0.6, 0)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 1.2 + Double(turns) * 0.4
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.7, 0.2, 1)
            medal.eulerAngles = SCNVector3(0, 0, 0)
            SCNTransaction.commit()
            yaw = 0
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let medal, let view = g.view else { return }
            let t = g.translation(in: view)
            switch g.state {
            case .began:
                medal.removeAllAnimations()
                startYaw = medal.presentation.eulerAngles.y
                medal.eulerAngles = medal.presentation.eulerAngles
            case .changed:
                yaw = startYaw + Float(t.x) * 0.012
                let pitch = max(-0.35, min(0.35, Float(t.y) * 0.004))
                medal.eulerAngles = SCNVector3(pitch, yaw, 0)
            case .ended, .cancelled:
                // Carry the flick on, then settle to the nearest face.
                let v = Float(g.velocity(in: view).x) * 0.012
                let projected = yaw + v * 0.35
                let target = (projected / .pi).rounded() * .pi
                let distance = abs(target - yaw)
                SCNTransaction.begin()
                SCNTransaction.animationDuration = Double(min(1.6, 0.45 + distance * 0.25))
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
                medal.eulerAngles = SCNVector3(0, target, 0)
                SCNTransaction.commit()
                yaw = target
            default:
                break
            }
        }
    }
}

/// A still render of an emblem, cached per content.
struct EmblemThumbnail: View {
    let content: EmblemContent
    @State private var image: UIImage?

    private var key: String {
        "\(content.entry.trackId)-\(content.locked)-\(content.driverName)-\(content.progress?.bestLap ?? 0)"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: key) {
            if let cached = EmblemThumbnailCache.images[key] { image = cached; return }
            let rendered = EmblemScene.snapshot(content, size: CGSize(width: 330, height: 330))
            EmblemThumbnailCache.images[key] = rendered
            image = rendered
        }
    }
}

@MainActor
enum EmblemThumbnailCache {
    static var images: [String: UIImage] = [:]
}
