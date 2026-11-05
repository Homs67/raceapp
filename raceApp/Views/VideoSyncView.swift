//
//  VideoSyncView.swift
//  raceApp
//
//  Lines a session's footage up with its data. A fixed playhead sits in the
//  middle of a zoomed timeline; the Session lane (speed trace) and a lane per
//  camera scroll under it. Drag a camera lane to slide its clips against the
//  session, drag anywhere else to scrub, pinch to zoom. The preview and the
//  mini-map show the moment under the playhead, so you line up what you see
//  (a kerb, a brake point) with the data.
//

import SwiftUI
import AVFoundation
import CoreLocation
import SessionKit

struct VideoSyncView: View {
    let sessionId: UUID
    let analysis: SessionAnalysis
    var onSaved: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var manifest: SessionManifest?
    @State private var sync = VideoSync()
    @State private var stored = VideoSync()
    @State private var axis: ClosedRange<TimeInterval> = 0...1
    /// Session seconds under the centre playhead.
    @State private var playhead: TimeInterval = 0
    @State private var playing = false
    @State private var playback = SessionVideoPlayback()
    @State private var preview: CameraSlot = .front
    /// Points per second of the timeline; pinch changes it.
    @State private var zoom: CGFloat = 16
    @State private var zoomAtPinchStart: CGFloat?
    /// A lane being dragged: the camera and its live shift in seconds.
    @State private var laneDrag: (camera: CameraSlot, seconds: TimeInterval)?
    @State private var scrubFrom: TimeInterval?
    @State private var thumbs: [UUID: [CGImage]] = [:]
    @State private var speedRange: ClosedRange<Double> = 0...1

    private let laneH: CGFloat = 56
    private let laneGap: CGFloat = 8
    private let thumbEvery: TimeInterval = 2

    private var assets: [VideoAsset] { manifest?.videos ?? [] }
    private var cameras: [CameraSlot] { CameraSlot.allCases.filter { c in assets.contains { $0.slot == c } } }
    private var sessionDuration: TimeInterval { manifest?.sessionDuration ?? 0 }
    private var changed: Bool { sync.frontOffset != stored.frontOffset || sync.rearOffset != stored.rearOffset }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    previewVideo.frame(maxWidth: .infinity, maxHeight: .infinity)
                    RouteMiniMap(analysis: analysis, at: dataIndex).equatable()
                        .frame(width: 124, height: 124)
                        .padding(.top, 20).padding(.trailing, 20)
                        .accessibilityHidden(true)
                }
                playButton.padding(.vertical, 16)
                timeline
            }
            .background(Color.black)
            .navigationTitle("Video Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { playback.pause(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }.disabled(!changed)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .task(id: playing) { await play() }
        .onChange(of: playhead) { if !playing { seekPreview() } }
    }

    // MARK: - Preview

    @ViewBuilder private var previewVideo: some View {
        let _ = playback.revision
        let feed = playback.feed(preview)
        if feed.compTime(at: clipTime(preview)) != nil {
            PlayerLayerView(player: feed.player).aspectRatio(16 / 9, contentMode: .fit)
        } else {
            Color(white: 0.07)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.system(size: 28)).foregroundStyle(Color.muted)
                        Text("No video here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mutedStrong)
                    }
                }
        }
    }

    private var playButton: some View {
        Button { playing.toggle() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: playing ? 0 : 2)
                .frame(width: 56, height: 56)
                .background(Color.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }

    // MARK: - Timeline

    private var timeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (TimeInterval) -> CGFloat = { w / 2 + CGFloat($0 - playhead) * zoom }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).gesture(scrubGesture)
                ruler(width: w, x: x)
                // A faint track per lane with its name, so a lane whose clips
                // are off-screen still reads as there.
                ForEach(Array((["Session"] + cameras.map(\.title)).enumerated()), id: \.offset) { row, name in
                    lane(row: row) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05))
                            .frame(width: w - 16, height: laneH)
                            .overlay(alignment: .bottomLeading) {
                                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mutedWeak)
                                    .padding(.leading, 8).padding(.bottom, 4)
                            }
                    }
                    .offset(x: 8)
                    .allowsHitTesting(false)
                }
                lane(row: 0) { sessionLane(width: w) }
                    .allowsHitTesting(false)
                ForEach(Array(cameras.enumerated()), id: \.element) { row, camera in
                    let shift = laneDrag?.camera == camera ? laneDrag!.seconds : 0
                    ForEach(assets.filter { $0.slot == camera }) { asset in
                        let span = VideoSyncLayout.span(of: asset, sessionStartUTC: manifest?.startedAtUTC ?? .now,
                                                        offset: sync.offset(for: camera) + shift)
                        let left = x(span.lowerBound)
                        lane(row: row + 1) {
                            clipLane(asset, width: max(2, x(span.upperBound) - left), left: left, screen: w)
                        }
                        .offset(x: left)
                        .gesture(laneGesture(camera))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(camera.title) camera, \(asset.fileName)")
                        .accessibilityValue("Starts at \(clock(span.lowerBound)) of the session")
                        .accessibilityAdjustableAction { dir in
                            sync.setOffset(sync.offset(for: camera) + (dir == .increment ? 0.1 : -0.1), for: camera)
                            Task { await rebuild() }
                        }
                    }
                }
                // Fixed centre playhead with the time on top.
                VStack(spacing: 4) {
                    Text(clock(playhead, tenths: true))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white, in: Capsule())
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 3)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                .frame(width: 80)
                .offset(x: w / 2 - 40)
                .allowsHitTesting(false)
                if let laneDrag {
                    Text("\(laneDrag.camera.title) \(String(format: "%+.1f s", laneDrag.seconds))")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accent, in: Capsule())
                        .frame(width: w, alignment: .center)
                        .offset(y: timelineHeight - 26)
                }
            }
            .frame(width: w, height: timelineHeight, alignment: .topLeading)
            .clipped()
            .gesture(MagnificationGesture()
                .onChanged { v in
                    let base = zoomAtPinchStart ?? zoom
                    zoomAtPinchStart = base
                    zoom = min(80, max(2, base * v))
                }
                .onEnded { _ in zoomAtPinchStart = nil })
        }
        .frame(height: timelineHeight)
        .padding(.bottom, 8)
    }

    private var rulerH: CGFloat { 26 }
    private var timelineHeight: CGFloat { rulerH + (laneH + laneGap) * CGFloat(1 + cameras.count) + 34 }

    private func lane<Content: View>(row: Int, @ViewBuilder content: () -> Content) -> some View {
        content().offset(y: rulerH + 8 + CGFloat(row) * (laneH + laneGap))
    }

    /// Tick marks every 1, 5, 10 or 30 s depending on zoom.
    private func ruler(width w: CGFloat, x: (TimeInterval) -> CGFloat) -> some View {
        let step: TimeInterval = zoom > 40 ? 1 : zoom > 12 ? 5 : zoom > 5 ? 10 : 30
        let lo = (playhead - Double(w / 2 / zoom)), hi = (playhead + Double(w / 2 / zoom))
        let first = (lo / step).rounded(.down) * step
        let ticks = Array(stride(from: first, through: hi, by: step)).map { ($0, x($0)) }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.0) { t, tx in
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 6)
                    Text(clock(t)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color.muted).fixedSize()
                }
                .offset(x: tx)
            }
        }
        .allowsHitTesting(false)
    }

    /// The session lane, drawn for the visible stretch only: a screen-wide
    /// canvas instead of one as wide as the whole session at this zoom.
    private func sessionLane(width w: CGFloat) -> some View {
        let x0 = w / 2 + CGFloat(0 - playhead) * zoom
        let x1 = w / 2 + CGFloat(sessionDuration - playhead) * zoom
        let lo = max(0, x0), hi = min(w, x1)
        return ZStack(alignment: .topLeading) {
            if hi > lo {
                Canvas { ctx, size in
                    let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Color.accent))
                    guard let manifest, speedRange.upperBound > speedRange.lowerBound else { return }
                    let values = analysis.channels[.speed] ?? []
                    let t = analysis.t
                    // Samples on screen, plus one either side.
                    let tLo = playhead - Double(w / 2 / zoom) + manifest.startUptime
                    let tHi = playhead + Double(w / 2 / zoom) + manifest.startUptime
                    let first = max(0, analysis.index(at: tLo) - 1)
                    let last = min(values.count - 1, analysis.index(at: tHi) + 1)
                    guard last > first else { return }
                    let step = max(1, (last - first) / 600)
                    let span = speedRange.upperBound - speedRange.lowerBound
                    var p = Path()
                    for k in stride(from: first, through: last, by: step) where t.indices.contains(k) {
                        let px = w / 2 + CGFloat(t[k] - manifest.startUptime - playhead) * zoom
                        let py = size.height - 4 - CGFloat((values[k] - speedRange.lowerBound) / span) * (size.height - 24)
                        if k == first { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    ctx.stroke(p, with: .color(.black.opacity(0.4)), lineWidth: 1.5)
                }
                .frame(width: w, height: laneH)
                .clipShape(Rectangle().offset(x: lo).size(width: hi - lo, height: laneH))
                Text("Session · \(clock(sessionDuration))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 8).padding(.top, 4)
                    .offset(x: max(lo, min(hi - 110, x0)))
            }
        }
        .frame(width: w, height: laneH, alignment: .topLeading)
    }

    /// A clip as a filmstrip. Only the tiles on screen are built, each showing
    /// the frame from the moment it covers, so the strip stays true at any zoom.
    private func clipLane(_ asset: VideoAsset, width: CGFloat, left: CGFloat, screen: CGFloat) -> some View {
        let tileW = laneH * 16 / 9
        let images = thumbs[asset.id] ?? []
        let tiles = Int((width / tileW).rounded(.up))
        let firstTile = max(0, Int((-left / tileW).rounded(.down)))
        let lastTile = min(tiles - 1, Int(((screen - left) / tileW).rounded(.up)))
        return ZStack(alignment: .topLeading) {
            if lastTile >= firstTile {
                ForEach(firstTile...lastTile, id: \.self) { i in
                    let t = Double(CGFloat(i) * tileW / zoom)
                    let k = min(images.count - 1, Int(t / thumbEvery))
                    Group {
                        if k >= 0 { Image(decorative: images[k], scale: 1).resizable().aspectRatio(contentMode: .fill) }
                        else { Color(white: 0.12) }
                    }
                    .frame(width: tileW, height: laneH).clipped()
                    .offset(x: CGFloat(i) * tileW)
                }
            }
            Text("\(asset.fileName) · \(clock(asset.duration))")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(maxWidth: min(220, max(0, width - 16)), alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .padding(4)
                .offset(x: max(0, min(width - 230, -left + 8)))
        }
        .frame(width: width, height: laneH, alignment: .topLeading)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(laneDrag == nil ? Color.clear : Color.accent, lineWidth: 2))
        .task(id: asset.id) { await loadThumbs(asset) }
    }

    // MARK: - Gestures

    /// Drag empty timeline or the session lane: the content follows the finger.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                playing = false
                let from = scrubFrom ?? playhead
                scrubFrom = from
                playhead = clamp(from - Double(g.translation.width / zoom))
            }
            .onEnded { _ in scrubFrom = nil }
    }

    /// Drag a camera lane sideways to slide its clips against the session.
    private func laneGesture(_ camera: CameraSlot) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                playing = false
                preview = camera
                laneDrag = (camera, Double(g.translation.width / zoom))
                seekPreview()
            }
            .onEnded { g in
                sync.setOffset(sync.offset(for: camera) + Double(g.translation.width / zoom), for: camera)
                laneDrag = nil
                Task { await rebuild() }
            }
    }

    private func clamp(_ t: TimeInterval) -> TimeInterval { min(axis.upperBound, max(axis.lowerBound, t)) }

    // MARK: - Playback

    /// The data sample under the playhead, for the mini-map dot.
    private var dataIndex: Int? {
        guard let manifest, playhead >= 0, playhead <= sessionDuration, !analysis.t.isEmpty else { return nil }
        return analysis.index(at: manifest.startUptime + playhead)
    }

    /// Where `camera`'s composition should be for the playhead, including a
    /// lane being dragged (its clips sample `seconds` earlier).
    private func clipTime(_ camera: CameraSlot) -> TimeInterval {
        let shift = laneDrag?.camera == camera ? laneDrag!.seconds : 0
        return playhead - axis.lowerBound - shift
    }

    private func seekPreview() {
        let feed = playback.feed(preview)
        guard let t = feed.compTime(at: clipTime(preview)) else { return }
        feed.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                         toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                         toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
    }

    private func play() async {
        guard playing else { playback.pause(); return }
        if playhead >= axis.upperBound - 0.1 { playhead = axis.lowerBound }
        var last = CACurrentMediaTime()
        while playing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            guard playing, !Task.isCancelled else { break }
            let now = CACurrentMediaTime()
            let dt = min(0.25, now - last)
            last = now
            // The video is the clock while it plays; elapsed time covers gaps.
            let feed = playback.feed(preview)
            if feed.player.rate > 0, feed.compTime(at: clipTime(preview)) != nil {
                playhead = feed.sessionTime + axis.lowerBound
            } else {
                playhead += dt
            }
            if playhead >= axis.upperBound { playhead = axis.upperBound; playing = false; break }
            playback.follow(sessionT: clipTime(preview), playing: true, audible: preview)
        }
        playback.pause()
    }

    // MARK: - Load / save

    private func load() async {
        manifest = try? model.store.manifest(for: sessionId)
        guard let manifest else { return }
        stored = manifest.effectiveVideoSync
        sync = stored
        let speeds = (analysis.channels[.speed] ?? []).filter(\.isFinite)
        if let lo = speeds.min(), let hi = speeds.max(), hi > lo { speedRange = lo...hi }
        // Clips that miss the session entirely start at the session instead.
        for camera in cameras {
            let spans = assets.filter { $0.slot == camera }.map {
                VideoSyncLayout.span(of: $0, sessionStartUTC: manifest.startedAtUTC, offset: sync.offset(for: camera))
            }
            if let fix = VideoSyncLayout.rescueOffset(spans: spans, sessionDuration: sessionDuration) {
                sync.setOffset(sync.offset(for: camera) + fix, for: camera)
            }
        }
        preview = cameras.first ?? .front
        // Start zoomed so about 20 s fills the screen.
        zoom = 402 / 20
        await rebuild()
        playhead = 0
        seekPreview()
    }

    /// Recompute the axis for the current offsets and reload the players on it.
    private func rebuild() async {
        guard let manifest else { return }
        let spans = assets.map { VideoSyncLayout.span(of: $0, sessionStartUTC: manifest.startedAtUTC, offset: sync.offset(for: $0.slot)) }
        axis = VideoSyncLayout.axis(sessionDuration: sessionDuration, spans: spans)
        playhead = clamp(playhead)
        await playback.load(assets: assets, origin: manifest.startedAtUTC.addingTimeInterval(axis.lowerBound),
                            duration: axis.upperBound - axis.lowerBound,
                            directory: model.store.directory(for: sessionId),
                            offsets: { sync.offset(for: $0) })
        seekPreview()
    }

    private func save() {
        guard var manifest else { return }
        manifest.videoSync = VideoSync(frontOffset: sync.frontOffset, rearOffset: sync.rearOffset)
        try? model.store.save(manifest)
        model.recording.sessionUpdated()
        playback.pause()
        onSaved()
        dismiss()
    }

    /// One frame every `thumbEvery` seconds (capped), drawn per tile by time.
    private func loadThumbs(_ asset: VideoAsset) async {
        guard thumbs[asset.id] == nil else { return }
        let url = model.store.directory(for: sessionId).appendingPathComponent("videos").appendingPathComponent(asset.fileName)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 112)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = max(1, min(300, Int((asset.duration / thumbEvery).rounded(.up))))
        var images: [CGImage] = []
        for i in 0..<count {
            let t = min(asset.duration - 0.1, Double(i) * thumbEvery)
            if let img = try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image {
                images.append(img)
            } else if let last = images.last { images.append(last) }
            if i % 15 == 14 { thumbs[asset.id] = images } // show the strip filling in
        }
        thumbs[asset.id] = images
    }

    /// 2:05 / −0:12, or 2:05.3 with tenths.
    private func clock(_ t: TimeInterval, tenths: Bool = false) -> String {
        let sign = t < -0.05 ? "−" : ""
        let a = abs(t)
        if tenths {
            let m = Int(a) / 60
            return sign + String(format: "%d:%04.1f", m, a - Double(m * 60))
        }
        let s = Int(a.rounded())
        return sign + String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The session's own GPS path with a dot at the playhead — the reference for
/// "where am I in the video". Works for drives as well as tracks.
struct RouteMiniMap: View, Equatable {
    let analysis: SessionAnalysis
    let at: Int?

    /// The route never changes here; only the dot does, at the data rate.
    static func == (a: Self, b: Self) -> Bool { a.at == b.at }

    var body: some View {
        Canvas { ctx, size in
            let n = analysis.lat.count
            guard n > 2 else { return }
            let step = max(1, n / 400)
            let idx = Array(stride(from: 0, to: n, by: step))
            // nil marks a GPS dropout; it must not reach min/max or the path.
            let pts = idx.map { analysis.coordinate($0) }
            let valid = pts.compactMap { $0 }
            guard let minLat = valid.map(\.latitude).min(), let maxLat = valid.map(\.latitude).max(),
                  let minLon = valid.map(\.longitude).min(), let maxLon = valid.map(\.longitude).max() else { return }
            let cosLat = cos((minLat + maxLat) / 2 * .pi / 180)
            let spanX = max(1e-6, (maxLon - minLon) * cosLat), spanY = max(1e-6, maxLat - minLat)
            let pad: CGFloat = 14
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY)
            let offX = (size.width - CGFloat(spanX) * scale) / 2, offY = (size.height - CGFloat(spanY) * scale) / 2
            func p(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(x: offX + CGFloat((lon - minLon) * cosLat) * scale, y: offY + CGFloat(maxLat - lat) * scale)
            }
            var path = Path()
            var pen = false
            for c in pts {
                guard let c else { pen = false; continue }   // lift the pen over a dropout
                let q = p(c.latitude, c.longitude)
                if pen { path.addLine(to: q) } else { path.move(to: q); pen = true }
            }
            ctx.stroke(path, with: .color(Color.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if let at, analysis.lat.indices.contains(at), let held = analysis.heldCoordinate(at: at) {
                let c = p(held.latitude, held.longitude)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.black), lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}
