//
//  VideoSyncView.swift
//  raceApp
//
//  Lines a session's footage up with its data, modelled on the iOS Photos
//  trimmer. One timeline holds a Session lane (the speed trace) and a lane per
//  camera; drag a lane sideways to align it, drag the white handles to crop.
//  The crop bounds what review plays — footage and data alike.
//

import SwiftUI
import AVFoundation
import SessionKit

struct VideoSyncView: View {
    let sessionId: UUID
    let analysis: SessionAnalysis
    var onSaved: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var manifest: SessionManifest?
    @State private var sync = VideoSync()
    @State private var saved = VideoSync()
    @State private var crop: ClosedRange<TimeInterval> = 0...1
    @State private var axis: ClosedRange<TimeInterval> = 0...1
    @State private var playhead: TimeInterval = 0
    @State private var playing = false
    @State private var playback = SessionVideoPlayback()
    @State private var preview: CameraSlot = .front
    /// Live drag of a lane, in seconds: camera lanes, or the session lane (nil).
    @State private var laneDrag: (lane: CameraSlot?, seconds: TimeInterval)?
    @State private var bubble: String?
    @State private var thumbs: [UUID: [CGImage]] = [:]
    @State private var cropAtDragStart: ClosedRange<TimeInterval>?

    private var assets: [VideoAsset] { manifest?.videos ?? [] }
    private var cameras: [CameraSlot] { CameraSlot.allCases.filter { c in assets.contains { $0.slot == c } } }
    private var sessionDuration: TimeInterval { manifest?.sessionDuration ?? 0 }
    private var changed: Bool {
        let savedCrop = saved.cropStart.flatMap { s in saved.cropEnd.map { s...$0 } }
        return sync.frontOffset != saved.frontOffset || sync.rearOffset != saved.rearOffset || cropValue != savedCrop
    }

    /// The crop worth saving: nil when it still covers the whole axis.
    private var cropValue: ClosedRange<TimeInterval>? {
        abs(crop.lowerBound - axis.lowerBound) < 0.05 && abs(crop.upperBound - axis.upperBound) < 0.05 ? nil : crop
    }

    var body: some View {
        VStack(spacing: 0) {
            nav
            ZStack(alignment: .topTrailing) {
                previewVideo.frame(maxWidth: .infinity, maxHeight: .infinity)
                RouteMiniMap(analysis: analysis, at: dataIndex)
                    .frame(width: 124, height: 124)
                    .padding(.top, 20).padding(.trailing, 20)
            }
            timeline.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task { await load() }
        .task(id: playing) { await play() }
        .onChange(of: playhead) { if !playing { seekPreview() } }
    }

    // MARK: - Chrome

    private var nav: some View {
        HStack {
            pillButton("Cancel") { dismiss() }
            Spacer()
            Text("VIDEO SYNC").font(.system(size: 15, weight: .medium)).tracking(0.6).foregroundStyle(Color.mutedStrong)
            Spacer()
            Button { save() } label: {
                Text("Done").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(changed ? Color.black : Color.mutedWeak)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(changed ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!changed)
        }
        .padding(.horizontal, 20).padding(.top, 6)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

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

    // MARK: - Timeline

    private let laneH: CGFloat = 40
    private let handleW: CGFloat = 14

    private var timeline: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 52).frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color.black).frame(width: 1.5)
                GeometryReader { geo in lanes(width: geo.size.width) }
                    .padding(.horizontal, 16)
            }
            .frame(height: laneH * CGFloat(1 + cameras.count) + 6 * CGFloat(cameras.count) + 16 + 16)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .top) {
                if let bubble {
                    Text(bubble).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .offset(y: -30)
                }
            }
            HStack {
                Text(clock(axis.lowerBound))
                Spacer()
                Text(clock(axis.upperBound))
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Color.muted)
            .padding(.leading, 52 + 16).padding(.trailing, 16)
        }
    }

    private func lanes(width w: CGFloat) -> some View {
        let x: (TimeInterval) -> CGFloat = { CGFloat(VideoSyncLayout.fraction($0, axis: axis)) * w }
        let secondsPerPoint = (axis.upperBound - axis.lowerBound) / Double(max(1, w))
        let sessionShift = laneDrag?.lane == nil ? (laneDrag?.seconds ?? 0) : 0
        return ZStack(alignment: .topLeading) {
            // Scrub strip along the top: drag to move the playhead.
            Color.clear.frame(width: w, height: 16).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    playing = false
                    playhead = min(axis.upperBound, max(axis.lowerBound, axis.lowerBound + Double(g.location.x) * secondsPerPoint))
                })
            // Session lane
            let s0 = x(sessionShift), s1 = x(sessionDuration + sessionShift)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.accent)
                ChannelLine(values: analysis.channels[.speed] ?? [], color: .black.opacity(0.35), symmetric: false)
                    .equatable().padding(.top, 14).padding(.bottom, 3)
                Text("Session · \(clock(sessionDuration))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 8).padding(.top, 3)
            }
            .frame(width: max(2, s1 - s0), height: laneH)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .offset(x: s0, y: 16)
            .gesture(laneGesture(nil, secondsPerPoint: secondsPerPoint))
            // Camera lanes
            ForEach(Array(cameras.enumerated()), id: \.element) { row, camera in
                let shift = laneDrag?.lane == camera ? (laneDrag?.seconds ?? 0) : 0
                ForEach(assets.filter { $0.slot == camera }) { asset in
                    let span = VideoSyncLayout.span(of: asset, sessionStartUTC: manifest?.startedAtUTC ?? .now,
                                                    offset: sync.offset(for: camera) + shift)
                    clipBlock(asset, width: max(2, x(span.upperBound) - x(span.lowerBound)))
                        .offset(x: x(span.lowerBound), y: 16 + (laneH + 6) * CGFloat(row + 1))
                        .gesture(laneGesture(camera, secondsPerPoint: secondsPerPoint))
                }
            }
            // Outside the crop dims; the white frame crops.
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, x(crop.lowerBound) + 16), height: totalHeight)
                .offset(x: -16).allowsHitTesting(false)
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, w - x(crop.upperBound) + 16), height: totalHeight)
                .offset(x: x(crop.upperBound)).allowsHitTesting(false)
            cropFrame(x0: x(crop.lowerBound), x1: x(crop.upperBound), secondsPerPoint: secondsPerPoint)
            // Playhead
            RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 4, height: totalHeight + 8)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .offset(x: x(playhead) - 2, y: -4).allowsHitTesting(false)
        }
        .frame(width: w, height: totalHeight, alignment: .topLeading)
        .padding(.vertical, 8)
    }

    private var totalHeight: CGFloat { 16 + laneH * CGFloat(1 + cameras.count) + 6 * CGFloat(cameras.count) }

    private func clipBlock(_ asset: VideoAsset, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array((thumbs[asset.id] ?? []).enumerated()), id: \.offset) { _, img in
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: laneH * 16 / 9, height: laneH).clipped()
                }
            }
            .frame(width: width, height: laneH, alignment: .leading)
            .clipped()
            Text("\(asset.fileName) · \(clock(asset.duration))")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .frame(maxWidth: max(0, width - 8), alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .padding(4)
        }
        .frame(width: width, height: laneH, alignment: .topLeading)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: asset.id) { await loadThumbs(asset, width: width) }
    }

    private func cropFrame(x0: CGFloat, x1: CGFloat, secondsPerPoint: Double) -> some View {
        let h = totalHeight + 16
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(width: x1 - x0 + 2 * handleW, height: 3)
            Rectangle().fill(Color.white).frame(width: x1 - x0 + 2 * handleW, height: 3).offset(y: h - 3)
            handle(left: true).offset(x: 0)
                .gesture(cropGesture(left: true, secondsPerPoint: secondsPerPoint))
            handle(left: false).offset(x: x1 - x0 + handleW)
                .gesture(cropGesture(left: false, secondsPerPoint: secondsPerPoint))
        }
        .frame(width: x1 - x0 + 2 * handleW, height: h, alignment: .topLeading)
        .offset(x: x0 - handleW, y: -8)
    }

    private func handle(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 8 : 0, bottomLeadingRadius: left ? 8 : 0,
                               bottomTrailingRadius: left ? 0 : 8, topTrailingRadius: left ? 0 : 8)
            .fill(Color.white)
            .frame(width: handleW, height: totalHeight + 16)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.black))
            .contentShape(Rectangle().inset(by: -10))
    }

    // MARK: - Gestures

    /// Drag a camera lane (or the session lane) sideways to line it up.
    private func laneGesture(_ lane: CameraSlot?, secondsPerPoint: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                playing = false
                let seconds = Double(g.translation.width) * secondsPerPoint
                laneDrag = (lane, seconds)
                if let lane { preview = lane }
                bubble = lane == nil ? "Session \(signed(seconds))" : "\(lane!.title) \(signed(seconds))"
                seekPreview()
            }
            .onEnded { g in
                let seconds = Double(g.translation.width) * secondsPerPoint
                if let lane {
                    sync.setOffset(sync.offset(for: lane) + seconds, for: lane)
                } else {
                    // Moving the session right is moving every camera left.
                    for c in CameraSlot.allCases { sync.setOffset(sync.offset(for: c) - seconds, for: c) }
                }
                laneDrag = nil
                bubble = nil
                Task { await rebuild(keepCrop: true) }
            }
    }

    private func cropGesture(left: Bool, secondsPerPoint: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                playing = false
                let start = cropAtDragStart ?? crop
                cropAtDragStart = start
                let t = (left ? start.lowerBound : start.upperBound) + Double(g.translation.width) * secondsPerPoint
                let proposed = left ? min(t, start.upperBound)...start.upperBound : start.lowerBound...max(t, start.lowerBound)
                crop = VideoSyncLayout.clampCrop(proposed, axis: axis)
                playhead = left ? crop.lowerBound : crop.upperBound
                bubble = clock(playhead)
            }
            .onEnded { _ in
                cropAtDragStart = nil
                bubble = nil
            }
    }

    // MARK: - Playback

    /// The data sample under the playhead, for the mini-map dot.
    private var dataIndex: Int? {
        guard let manifest, playhead >= 0, playhead <= sessionDuration, !analysis.t.isEmpty else { return nil }
        return analysis.index(at: manifest.startUptime + playhead)
    }

    /// Where `camera`'s composition should be for the playhead, including a
    /// lane being dragged (its clips sample `seconds` earlier).
    private func clipTime(_ camera: CameraSlot) -> TimeInterval {
        var shift: TimeInterval = 0
        if let d = laneDrag { shift = d.lane == camera ? d.seconds : (d.lane == nil ? -d.seconds : 0) }
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
        if playhead >= crop.upperBound - 0.1 { playhead = crop.lowerBound }
        while playing, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            playhead += 1.0 / 30
            if playhead >= crop.upperBound { playhead = crop.upperBound; playing = false }
            playback.follow(sessionT: clipTime(preview), playing: playing, audible: preview)
        }
        playback.pause()
    }

    // MARK: - Load / save

    private func load() async {
        manifest = try? model.store.manifest(for: sessionId)
        guard let manifest else { return }
        let stored = manifest.effectiveVideoSync
        sync = stored
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
        await rebuild(keepCrop: false)
        if let s = sync.cropStart, let e = sync.cropEnd { crop = VideoSyncLayout.clampCrop(s...e, axis: axis) }
        // Baseline is what's stored, so a rescued placement still needs Done.
        saved = VideoSync(frontOffset: stored.frontOffset, rearOffset: stored.rearOffset,
                          cropStart: cropValue?.lowerBound, cropEnd: cropValue?.upperBound)
        playhead = max(axis.lowerBound, min(0, axis.upperBound))
        seekPreview()
    }

    /// Recompute the axis for the current offsets and reload the players on it.
    private func rebuild(keepCrop: Bool) async {
        guard let manifest else { return }
        let spans = assets.map { VideoSyncLayout.span(of: $0, sessionStartUTC: manifest.startedAtUTC, offset: sync.offset(for: $0.slot)) }
        let wasFull = cropValue == nil
        axis = VideoSyncLayout.axis(sessionDuration: sessionDuration, spans: spans)
        crop = keepCrop && !wasFull ? VideoSyncLayout.clampCrop(crop, axis: axis) : axis
        await playback.load(assets: assets, origin: manifest.startedAtUTC.addingTimeInterval(axis.lowerBound),
                            duration: axis.upperBound - axis.lowerBound,
                            directory: model.store.directory(for: sessionId),
                            offsets: { sync.offset(for: $0) })
        seekPreview()
    }

    private func save() {
        guard var manifest else { return }
        var out = sync
        out.cropStart = cropValue?.lowerBound
        out.cropEnd = cropValue?.upperBound
        manifest.videoSync = out
        try? model.store.save(manifest)
        model.recording.sessionUpdated()
        playback.pause()
        onSaved()
        dismiss()
    }

    private func loadThumbs(_ asset: VideoAsset, width: CGFloat) async {
        guard thumbs[asset.id] == nil else { return }
        let url = model.store.directory(for: sessionId).appendingPathComponent("videos").appendingPathComponent(asset.fileName)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let count = max(1, min(24, Int((width / (laneH * 16 / 9)).rounded(.up))))
        var images: [CGImage] = []
        for i in 0..<count {
            let t = asset.duration * (Double(i) + 0.5) / Double(count)
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(img) }
        }
        thumbs[asset.id] = images
    }

    private func signed(_ s: TimeInterval) -> String { String(format: "%+.1f s", s) }

    /// 2:05 or −0:12 — axis ends can sit before the session starts.
    private func clock(_ t: TimeInterval) -> String {
        let s = Int(abs(t).rounded())
        return (t < -0.5 ? "−" : "") + String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The session's own GPS path with a dot at the playhead — the reference for
/// "where am I in the video". Works for drives as well as tracks.
struct RouteMiniMap: View {
    let analysis: SessionAnalysis
    let at: Int?

    var body: some View {
        Canvas { ctx, size in
            let n = analysis.lat.count
            guard n > 2 else { return }
            let step = max(1, n / 400)
            let idx = Array(stride(from: 0, to: n, by: step))
            let lats = idx.map { analysis.lat[$0] }, lons = idx.map { analysis.lon[$0] }
            guard let minLat = lats.min(), let maxLat = lats.max(), let minLon = lons.min(), let maxLon = lons.max() else { return }
            let cosLat = cos((minLat + maxLat) / 2 * .pi / 180)
            let spanX = max(1e-6, (maxLon - minLon) * cosLat), spanY = max(1e-6, maxLat - minLat)
            let pad: CGFloat = 14
            let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY)
            let offX = (size.width - CGFloat(spanX) * scale) / 2, offY = (size.height - CGFloat(spanY) * scale) / 2
            func p(_ lat: Double, _ lon: Double) -> CGPoint {
                CGPoint(x: offX + CGFloat((lon - minLon) * cosLat) * scale, y: offY + CGFloat(maxLat - lat) * scale)
            }
            var path = Path()
            path.addLines(zip(lats, lons).map { p($0, $1) })
            ctx.stroke(path, with: .color(Color.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if let at, analysis.lat.indices.contains(at) {
                let c = p(analysis.lat[at], analysis.lon[at])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.black), lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}
