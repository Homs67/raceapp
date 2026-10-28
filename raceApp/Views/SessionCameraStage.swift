//
//  SessionCameraStage.swift
//  raceApp
//
//  The Camera half of the session map: two stitched footage players (front =
//  road ahead, rear = the other camera) locked to session time, and the stage
//  that shows one big with the other in a corner. The map's cursor stays the
//  clock; this only follows it, or drives it while footage plays.
//

import SwiftUI
import AVFoundation
import SessionKit

/// Which camera a clip shows as in review (front = road ahead).
typealias CameraSlot = VideoAsset.Camera

extension VideoAsset.Camera {
    var title: String { self == .front ? "Front" : "Rear" }
    var other: Self { self == .front ? .rear : .front }
}

@MainActor @Observable
final class SessionVideoPlayback {
    final class Feed {
        let player = AVPlayer()
        var compact: [VideoTimeline.CompactSegment] = []
        var hasFootage: Bool { !compact.isEmpty }

        /// Footage time for a session time, or nil when this camera has a gap there.
        func compTime(at sessionT: TimeInterval) -> TimeInterval? {
            for c in compact where sessionT >= c.segment.sessionStart - 0.001 && sessionT <= c.segment.sessionEnd + 0.001 {
                return c.compStart + (sessionT - c.segment.sessionStart)
            }
            return nil
        }

        var sessionTime: TimeInterval {
            VideoTimeline.sessionTime(atCompositionTime: player.currentTime().seconds, in: compact)
        }

        /// Start of the next footage after `sessionT`, for the gap card.
        func nextStart(after sessionT: TimeInterval) -> TimeInterval? {
            compact.first { $0.segment.sessionStart > sessionT }?.segment.sessionStart
        }
    }

    private(set) var feeds: [CameraSlot: Feed] = [.front: Feed(), .rear: Feed()]
    private(set) var loaded = false
    /// Bumped after every load so views redraw: the feeds themselves aren't observed.
    private(set) var revision = 0
    private var lastSeekAt: CFTimeInterval = 0

    var hasVideo: Bool { feeds.values.contains { $0.hasFootage } }
    func feed(_ slot: CameraSlot) -> Feed { feeds[slot]! }

    /// Review playback: each camera's clips on the session clock, with its
    /// saved offset, limited to the Video sync crop.
    func load(manifest: SessionManifest, directory: URL) async {
        let sync = manifest.effectiveVideoSync
        await load(assets: manifest.videos ?? [], origin: manifest.startedAtUTC,
                   duration: manifest.sessionDuration, directory: directory,
                   offsets: { sync.offset(for: $0) },
                   window: sync.reviewWindow(sessionDuration: manifest.sessionDuration))
    }

    /// General form: place clips on a timeline that starts at `origin` and
    /// runs `duration` seconds (Video sync uses one wider than the session).
    func load(assets: [VideoAsset], origin: Date, duration: TimeInterval, directory: URL,
              offsets: (CameraSlot) -> TimeInterval, window: ClosedRange<TimeInterval>? = nil) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        for slot in CameraSlot.allCases {
            let feed = feed(slot)
            let mine = assets.filter { $0.slot == slot }
            let segments = VideoTimeline.segments(assets: mine, sessionStartUTC: origin,
                                                  sessionDuration: duration,
                                                  syncOffset: offsets(slot), window: window)
            feed.compact = VideoTimeline.compact(segments)
            guard feed.hasFootage,
                  let built = try? await VideoLibrary.buildComposition(compact: feed.compact, sessionDirectory: directory)
            else { feed.player.replaceCurrentItem(with: nil); continue }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            feed.player.replaceCurrentItem(with: item)
            feed.player.pause()
        }
        loaded = true
        revision += 1
    }

    /// Put both cameras on `sessionT`. Throttled to ~20 seeks/s while scrubbing.
    func seek(to sessionT: TimeInterval, precise: Bool = false) {
        let now = CACurrentMediaTime()
        guard precise || now - lastSeekAt > 0.05 else { return }
        lastSeekAt = now
        let tol = CMTime(seconds: precise ? 0.02 : 0.1, preferredTimescale: 600)
        for feed in feeds.values {
            guard let t = feed.compTime(at: sessionT) else { continue }
            feed.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        }
    }

    /// Keep each camera playing where it has footage and paused where it
    /// doesn't, re-seeking only when it has drifted more than 0.25 s.
    func follow(sessionT: TimeInterval, playing: Bool, audible: CameraSlot) {
        for (slot, feed) in feeds {
            feed.player.isMuted = slot != audible
            guard playing, let t = feed.compTime(at: sessionT) else {
                feed.player.pause()
                continue
            }
            if abs(feed.player.currentTime().seconds - t) > 0.25 {
                feed.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                 toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                                 toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
            }
            if feed.player.rate == 0 { feed.player.play() }
        }
    }

    func pause() { feeds.values.forEach { $0.player.pause() } }
}

// MARK: - Stage

enum PipCorner: String { case topLeading, topTrailing, bottomLeading, bottomTrailing }

/// Main camera at 16:9 in the middle of the top area; the other camera in a
/// corner. Tap the corner camera to swap; drag it anywhere and it sticks to
/// the nearest corner on release.
struct SessionCameraStage: View {
    let playback: SessionVideoPlayback
    let sessionT: TimeInterval
    @Binding var main: CameraSlot
    var onJump: (TimeInterval) -> Void

    @AppStorage("cameraPipCorner") private var cornerRaw = PipCorner.topTrailing.rawValue
    @State private var drag: CGSize = .zero

    private let pipSize = CGSize(width: 144, height: 81)
    private let inset: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let _ = playback.revision
            let mainFeed = playback.feed(main)
            let secondary = playback.feed(main.other)
            ZStack {
                if mainFeed.compTime(at: sessionT) != nil {
                    PlayerLayerView(player: mainFeed.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    gapCard(next: mainFeed.nextStart(after: sessionT))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if secondary.hasFootage {
                    pip(secondary, in: geo.size)
                }
            }
        }
    }

    private func gapCard(next: TimeInterval?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash").font(.system(size: 30, weight: .regular)).foregroundStyle(Color.muted)
            Text("No video for this part").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            if let next {
                Button { onJump(next) } label: {
                    Text("Jump to next clip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07))
    }

    private func pip(_ feed: SessionVideoPlayback.Feed, in size: CGSize) -> some View {
        let corner = PipCorner(rawValue: cornerRaw) ?? .topTrailing
        let origin = position(corner, in: size)
        return ZStack(alignment: .bottomLeading) {
            if feed.compTime(at: sessionT) != nil {
                PlayerLayerView(player: feed.player)
            } else {
                Color(white: 0.07)
                Image(systemName: "video.slash").foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Label(main.other.title, systemImage: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .padding(6)
        }
        .frame(width: pipSize.width, height: pipSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.22), lineWidth: 1.5))
        .shadow(color: .black.opacity(drag == .zero ? 0.5 : 0.7), radius: drag == .zero ? 9 : 15, y: drag == .zero ? 6 : 14)
        .scaleEffect(drag == .zero ? 1 : 1.06)
        .position(x: origin.x + pipSize.width / 2 + drag.width, y: origin.y + pipSize.height / 2 + drag.height)
        .onTapGesture { withAnimation(.snappy) { main = main.other } }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation }
            .onEnded { g in
                let center = CGPoint(x: origin.x + pipSize.width / 2 + g.predictedEndTranslation.width,
                                     y: origin.y + pipSize.height / 2 + g.predictedEndTranslation.height)
                let left = center.x < size.width / 2, top = center.y < size.height / 2
                let next: PipCorner = top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                    cornerRaw = next.rawValue
                    drag = .zero
                }
            })
    }

    private func position(_ corner: PipCorner, in size: CGSize) -> CGPoint {
        let x = corner == .topLeading || corner == .bottomLeading ? inset : size.width - inset - pipSize.width
        let y = corner == .topLeading || corner == .topTrailing ? inset : size.height - inset - pipSize.height
        return CGPoint(x: x, y: y)
    }
}

/// Chrome-free AVPlayerLayer (no system controls; the map panel is the transport).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class Container: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
