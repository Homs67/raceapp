//
//  DualCameraSwapView.swift
//  raceApp
//
//  Shared dual-camera chrome: full-bleed primary + top-leading PiP.
//  Tap the PiP to spring-swap which feed is primary (review + live preview).
//

import SwiftUI
import AVFoundation
import UIKit

enum DualCameraPipMetrics {
    static let padding: CGFloat = 10
    static let cornerRadius: CGFloat = 8

    /// PiP sized to the feed's oriented aspect (portrait → tall, landscape → wide).
    /// `aspectRatio` is width / height of the upright video frame.
    static func size(for container: CGSize, aspectRatio: CGFloat = 16 / 9) -> CGSize {
        let ratio = aspectRatio > 0.05 ? aspectRatio : 16 / 9
        let longest = min(148, max(96, container.width * 0.28))
        if ratio >= 1 {
            return CGSize(width: longest, height: longest / ratio)
        }
        return CGSize(width: longest * ratio, height: longest)
    }

    /// Oriented width/height aspect from a live preview connection.
    static func aspectRatio(for preview: AVCaptureVideoPreviewLayer?) -> CGFloat {
        guard let connection = preview?.connection else { return 9 / 16 }
        let device = connection.inputPorts
            .compactMap { $0.input as? AVCaptureDeviceInput }
            .map(\.device)
            .first
        guard let device else { return 9 / 16 }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var width = CGFloat(dims.width)
        var height = CGFloat(dims.height)
        guard width > 1, height > 1 else { return 9 / 16 }
        let angle = connection.videoRotationAngle
        // 90° / 270° swap sensor axes into upright display size.
        if abs(angle.truncatingRemainder(dividingBy: 180) - 90) < 1 {
            swap(&width, &height)
        }
        return width / height
    }
}

/// SwiftUI dual stack (video review): rear + front players with tap-to-swap.
struct DualCameraSwapStack<Rear: View, Front: View>: View {
    /// When true, front fills the pane and rear is the PiP.
    @Binding var frontIsPrimary: Bool
    var showFront: Bool
    var frontVisible: Bool
    /// Oriented width/height of each feed (drives PiP border shape).
    var rearAspectRatio: CGFloat = 16 / 9
    var frontAspectRatio: CGFloat = 9 / 16
    @ViewBuilder var rear: () -> Rear
    @ViewBuilder var front: () -> Front

    var body: some View {
        GeometryReader { geo in
            let pad = DualCameraPipMetrics.padding
            let full = CGRect(origin: .zero, size: geo.size)
            let swapped = frontIsPrimary && showFront

            // PiP border follows whichever feed is small right now.
            let pipAspect = swapped ? rearAspectRatio : frontAspectRatio
            let pip = DualCameraPipMetrics.size(for: geo.size, aspectRatio: pipAspect)
            let pipRect = CGRect(x: pad, y: pad, width: pip.width, height: pip.height)

            let rearRect = swapped ? pipRect : full
            let frontRect = swapped ? full : pipRect
            let rearIsPip = swapped
            let frontIsPip = !swapped

            ZStack(alignment: .topLeading) {
                cameraChrome(
                    content: rear(),
                    frame: rearRect,
                    isPip: rearIsPip,
                    label: rearIsPip ? "Rear camera, tap to enlarge" : "Rear camera"
                ) {
                    guard rearIsPip else { return }
                    frontIsPrimary = false
                }
                .zIndex(rearIsPip ? 2 : 0)

                if showFront {
                    cameraChrome(
                        content: front(),
                        frame: frontRect,
                        isPip: frontIsPip,
                        label: frontIsPip ? "Front camera, tap to enlarge" : "Front camera"
                    ) {
                        guard frontIsPip, frontVisible else { return }
                        frontIsPrimary = true
                    }
                    .opacity(frontIsPip && !frontVisible ? 0 : 1)
                    .zIndex(frontIsPip ? 2 : 1)
                    .allowsHitTesting(frontVisible || !frontIsPip)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func cameraChrome<Content: View>(
        content: Content,
        frame: CGRect,
        isPip: Bool,
        label: String,
        onTap: @escaping () -> Void
    ) -> some View {
        content
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(
                cornerRadius: isPip ? DualCameraPipMetrics.cornerRadius : 0,
                style: .continuous))
            .overlay {
                if isPip {
                    RoundedRectangle(cornerRadius: DualCameraPipMetrics.cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
            }
            .shadow(color: isPip ? .black.opacity(0.45) : .clear, radius: isPip ? 6 : 0, y: isPip ? 2 : 0)
            .offset(x: frame.minX, y: frame.minY)
            .contentShape(Rectangle())
            // Only PiP steals taps (to swap). The main feed must receive them so
            // VideoPlayer can show native playback controls in review.
            .modifier(PipTapModifier(enabled: isPip, action: onTap))
            .accessibilityLabel(label)
            .accessibilityAddTraits(isPip ? .isButton : [])
    }
}

private struct PipTapModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Live capture preview (UIKit layers) with the same tap-to-swap

struct DualCameraPreviewView: UIViewRepresentable {
    let rearLayer: AVCaptureVideoPreviewLayer
    let frontLayer: AVCaptureVideoPreviewLayer?
    let landscape: Bool
    @Binding var frontIsPrimary: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let host = PreviewHostView()
        host.backgroundColor = .black
        host.onToggle = { primaryFront in
            frontIsPrimary = primaryFront
        }
        return host
    }

    func updateUIView(_ host: PreviewHostView, context: Context) {
        host.onToggle = { primaryFront in
            frontIsPrimary = primaryFront
        }
        host.attach(
            rear: rearLayer,
            front: frontLayer,
            landscape: landscape,
            frontIsPrimary: frontIsPrimary,
            animated: false
        )
        context.coordinator.lastFrontIsPrimary = frontIsPrimary
    }

    final class Coordinator {
        var lastFrontIsPrimary = false
    }

    final class PreviewHostView: UIView {
        private weak var rear: AVCaptureVideoPreviewLayer?
        private weak var front: AVCaptureVideoPreviewLayer?
        private var landscape = false
        private var frontIsPrimary = false
        var onToggle: ((Bool) -> Void)?

        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func attach(
            rear: AVCaptureVideoPreviewLayer,
            front: AVCaptureVideoPreviewLayer?,
            landscape: Bool,
            frontIsPrimary: Bool,
            animated: Bool
        ) {
            self.landscape = landscape
            self.frontIsPrimary = frontIsPrimary
            if rear !== self.rear {
                self.rear?.removeFromSuperlayer()
                layer.addSublayer(rear)
                self.rear = rear
            }
            if front !== self.front {
                self.front?.removeFromSuperlayer()
                if let front {
                    layer.addSublayer(front)
                    front.masksToBounds = true
                }
                self.front = front
            }
            layoutPreviewFrames(animated: animated)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutPreviewFrames(animated: false)
        }

        private func layoutPreviewFrames(animated: Bool) {
            guard let rear else { return }
            // Orient first so aspect matches the upright video frame.
            applyOrientation(rear, position: .back)
            if let front {
                applyOrientation(front, position: .front)
            }

            let pipAspect = frontIsPrimary
                ? DualCameraPipMetrics.aspectRatio(for: rear)
                : DualCameraPipMetrics.aspectRatio(for: front ?? rear)
            let pip = DualCameraPipMetrics.size(for: bounds.size, aspectRatio: pipAspect)
            let pipFrame = CGRect(
                x: DualCameraPipMetrics.padding,
                y: DualCameraPipMetrics.padding,
                width: pip.width,
                height: pip.height
            )
            let fullFrame = bounds

            let rearFrame = frontIsPrimary ? pipFrame : fullFrame
            let frontFrame = frontIsPrimary ? fullFrame : pipFrame
            let rearIsPip = frontIsPrimary
            let frontIsPip = !frontIsPrimary

            let apply = {
                rear.frame = rearFrame
                rear.videoGravity = .resizeAspectFill
                rear.cornerRadius = rearIsPip ? DualCameraPipMetrics.cornerRadius : 0
                rear.borderWidth = rearIsPip ? 1 : 0
                rear.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
                rear.zPosition = rearIsPip ? 2 : 0

                if let front = self.front {
                    front.frame = frontFrame
                    front.videoGravity = .resizeAspectFill
                    front.cornerRadius = frontIsPip ? DualCameraPipMetrics.cornerRadius : 0
                    front.borderWidth = frontIsPip ? 1 : 0
                    front.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
                    front.zPosition = frontIsPip ? 2 : 0
                }
            }

            if animated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.42)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(name: .easeInEaseOut))
                apply()
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                apply()
                CATransaction.commit()
            }
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard front != nil else { return }
            let point = gesture.location(in: self)
            let pipAspect = frontIsPrimary
                ? DualCameraPipMetrics.aspectRatio(for: rear)
                : DualCameraPipMetrics.aspectRatio(for: front)
            let pip = DualCameraPipMetrics.size(for: bounds.size, aspectRatio: pipAspect)
            let pipFrame = CGRect(
                x: DualCameraPipMetrics.padding,
                y: DualCameraPipMetrics.padding,
                width: pip.width,
                height: pip.height
            )
            guard pipFrame.contains(point) else { return }
            // Tap PiP → promote it to primary.
            onToggle?(!frontIsPrimary)
        }

        /// Horizon-level rotation from AVFoundation (handles front vs rear mounting).
        private func applyOrientation(_ preview: AVCaptureVideoPreviewLayer?,
                                      position: AVCaptureDevice.Position) {
            guard let preview, let connection = preview.connection else { return }

            // Prefer the device wired to this preview connection.
            let device = connection.inputPorts
                .compactMap { $0.input as? AVCaptureDeviceInput }
                .map(\.device)
                .first
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)

            if let device {
                let coordinator = AVCaptureDevice.RotationCoordinator(
                    device: device, previewLayer: preview)
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            } else {
                // Fallback if the connection isn't ready yet.
                let ui = window?.windowScene?.interfaceOrientation
                    ?? (landscape ? .landscapeRight : .portrait)
                let angle: CGFloat
                switch ui {
                case .portrait: angle = position == .front ? 270 : 90
                case .portraitUpsideDown: angle = position == .front ? 90 : 270
                case .landscapeLeft: angle = position == .front ? 0 : 180
                case .landscapeRight: angle = position == .front ? 180 : 0
                default: angle = landscape ? 0 : (position == .front ? 270 : 90)
                }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            // Front camera should mirror like a selfie preview.
            if position == .front, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}
