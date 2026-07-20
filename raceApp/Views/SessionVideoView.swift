//
//  SessionVideoView.swift
//  raceApp
//
//  Split-screen video review: stitched session-cropped video on top, the
//  session graphs below with a playhead that tracks playback, a live value
//  strip, switchable metrics, and two-way scrubbing (drag the graph → seek).
//

import SwiftUI
import AVKit
import Charts
import SessionKit
import ObdKit

struct SessionVideoView: View {
    let sessionId: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetricUnits") private var metric = false

    @State private var manifest: SessionManifest?
    @State private var player = AVPlayer()
    @State private var segments: [VideoSegment] = []
    @State private var gaps: [(start: TimeInterval, end: TimeInterval)] = []
    @State private var series: [MetricSeries] = []
    @State private var selectedSeriesId: String?
    @State private var currentT: TimeInterval = 0
    @State private var isPlaying = false
    @State private var scrubT: TimeInterval?
    @State private var lastSeekAt: CFTimeInterval = 0
    @State private var timeObserver: Any?
    @State private var cursors: [String: ChannelSampleCursor] = [:]
    @State private var showSync = false
    @State private var syncOffset: Double = 0
    @State private var loading = true

    private var sessionDuration: TimeInterval {
        manifest?.highlights?.durationSeconds ?? 0
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                layout(landscape: landscape)
            }
            .background(Color.black)
            .navigationTitle("Video Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sync") { showSync = true }
                        .disabled(loading)
                }
            }
        }
        .task { await load() }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
        .sheet(isPresented: $showSync) { syncSheet }
    }

    @ViewBuilder
    private func layout(landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: 0) {
                videoPane
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    valueStrip
                    transportRow
                    graphPane
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        } else {
            VStack(spacing: 0) {
                videoPane
                    .frame(maxHeight: .infinity)
                VStack(spacing: 10) {
                    valueStrip
                    transportRow
                    graphPane
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    player.pause()
                    isPlaying = false
                } else {
                    player.play()
                    isPlaying = true
                }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
            .disabled(loading)

            Text("\(timeLabel(currentT)) / \(timeLabel(sessionDuration))")
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color.textPrimary)

            Spacer()

            if isPlaying {
                HStack(spacing: 5) {
                    Circle().fill(Color.accent).frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .semibold)).kerning(1)
                        .foregroundStyle(Color.accent)
                }
            } else if !loading {
                Text("Scroll graph to move through time")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mutedWeak)
            }
        }
    }

    // MARK: - Video

    private var videoPane: some View {
        ZStack {
            VideoPlayer(player: player)
            if loading {
                ProgressView().tint(.white)
            } else if inGap {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.mutedStrong)
                    Text("NO FOOTAGE")
                        .font(.system(size: 11, weight: .semibold)).kerning(1.5)
                        .foregroundStyle(Color.mutedStrong)
                }
                .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }

    private var inGap: Bool {
        gaps.contains { currentT >= $0.start + 0.3 && currentT <= $0.end - 0.3 }
    }

    // MARK: - Value strip (exact values at the current frame)

    private var valueStrip: some View {
        let units = UnitsFormatter(metric: metric)
        let t = (manifest?.startUptime ?? 0) + currentT
        return HStack(spacing: 0) {
            stripValue("SPEED", cursors["speed"]?.value(at: t).map {
                "\(Int(units.speed(fromMps: $0)))"
            }, unit: units.speedUnit.lowercased())
            stripValue("RPM", cursors["rpm"]?.value(at: t).map { "\(Int($0))" })
            stripValue("THR", cursors["throttle"]?.value(at: t).map { "\(Int($0))%" })
            stripValue("LAT", cursors["latG"]?.value(at: t, tolerance: 1).map {
                String(format: "%.2fg", $0)
            })
            stripValue("LONG", cursors["longG"]?.value(at: t, tolerance: 1).map {
                String(format: "%.2fg", $0)
            })
            stripValue("TIME", timeLabel(currentT))
        }
        .padding(.vertical, 8)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stripValue(_ label: String, _ value: String?, unit: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold)).kerning(1)
                .foregroundStyle(Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(value == nil ? Color.mutedWeak : Color.textPrimary)
                if let unit, value != nil {
                    Text(unit).font(.system(size: 9)).foregroundStyle(Color.muted)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Graph with playhead + scrub-to-seek

    private var graphPane: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(series) { s in
                        Button {
                            selectedSeriesId = s.id
                        } label: {
                            Text(s.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedSeriesId == s.id ? Color.black : Color.textPrimary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(selectedSeriesId == s.id ? Color.accent : Color.cardGray,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let current = series.first(where: { $0.id == selectedSeriesId }) ?? series.first {
                // Frame-rate clock: the chart reads the player's time every display
                // frame (not the 10Hz observer), so the window glides smoothly.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                        paused: !isPlaying && scrubT == nil)) { _ in
                    PlayheadChart(
                        series: current,
                        playhead: scrubT ?? (isPlaying ? player.currentTime().seconds : currentT),
                        window: 20,
                        sessionDuration: sessionDuration,
                        onScrubBegan: {
                            player.pause()
                            isPlaying = false
                        },
                        onScrub: { t in scrub(to: t) },
                        onScrubEnded: { finishScrub() }
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
    }

    private func seek(to t: TimeInterval) {
        let clamped = max(0, min(sessionDuration, t))
        currentT = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.15, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.15, preferredTimescale: 600))
    }

    /// Finger-driven scrub: the graph follows `scrubT` frame-perfectly while
    /// video seeks are throttled (~20/s) so AVPlayer can keep up.
    private func scrub(to t: TimeInterval) {
        let clamped = max(0, min(sessionDuration, t))
        scrubT = clamped
        currentT = clamped // keeps the value strip + transport in step
        let now = CACurrentMediaTime()
        guard now - lastSeekAt > 0.05 else { return }
        lastSeekAt = now
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    private func finishScrub() {
        if let t = scrubT {
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 0.02, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.02, preferredTimescale: 600))
        }
        scrubT = nil
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Sync nudge

    private var syncSheet: some View {
        VStack(spacing: 18) {
            Text("Sync video to data")
                .font(.system(size: 17, weight: .semibold))
            Text("Find a recognizable moment (a launch, a hard brake) and nudge until the graphs match the video. Applies to all clips.")
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
            Text(String(format: "%+.1f s", syncOffset))
                .font(.numeral(34, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.accent)
            HStack(spacing: 10) {
                ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { step in
                    Button {
                        syncOffset += step
                    } label: {
                        Text(String(format: "%+g", step))
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .frame(width: 64, height: 40)
                            .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showSync = false
                Task { await applySync() }
            } label: {
                Text("Apply")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Color.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .presentationDetents([.height(300)])
        .presentationBackground(Color.bgSheet)
    }

    private func applySync() async {
        guard var manifest else { return }
        manifest.videoSyncOffset = syncOffset
        try? model.store.save(manifest)
        self.manifest = manifest
        await rebuildPlayer()
    }

    // MARK: - Loading

    private func load() async {
        // Play audio through the speaker even with the silent switch on
        // (dashcam/GoPro sound is the point of video review).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.isMuted = false
        player.volume = 1

        manifest = try? model.store.manifest(for: sessionId)
        guard let manifest else { return }
        syncOffset = manifest.videoSyncOffset ?? 0
        let directory = model.store.directory(for: sessionId)
        let metricFlag = metric

        // Graph series + value cursors off-main
        let loaded: ([MetricSeries], [String: ChannelSampleCursor]) = await Task.detached {
            let series = MetricSeries.build(directory: directory, manifest: manifest, metric: metricFlag)
            var cursors: [String: ChannelSampleCursor] = [:]
            let obdSpeed = ChannelReader.samples(for: .obd(.speed), inSessionDirectory: directory)
            cursors["speed"] = ChannelSampleCursor(
                samples: obdSpeed.isEmpty
                    ? ChannelReader.samples(for: .gpsSpeed, inSessionDirectory: directory)
                    : obdSpeed.map { ChannelSample(t: $0.t, value: $0.value / 3.6) }) // km/h → m/s
            cursors["rpm"] = ChannelSampleCursor(channel: .obd(.rpm), sessionDirectory: directory)
            cursors["throttle"] = ChannelSampleCursor(channel: .obd(.throttle), sessionDirectory: directory)
            cursors["latG"] = ChannelSampleCursor(channel: .carLatG, sessionDirectory: directory)
            cursors["longG"] = ChannelSampleCursor(channel: .carLongG, sessionDirectory: directory)
            return (series, cursors)
        }.value
        series = loaded.0
        cursors = loaded.1
        selectedSeriesId = series.first?.id

        await rebuildPlayer()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { time in
            currentT = time.seconds
            // Tracks the native video controls too (play/pause from either place)
            isPlaying = player.rate > 0
        }
        player.pause() // open paused, in overview mode
        #if DEBUG
        if CommandLine.arguments.contains("-video-autoplay") {
            player.play()
            isPlaying = true
        }
        #endif
        loading = false
    }

    private func rebuildPlayer() async {
        guard let manifest, let assets = manifest.videos, !assets.isEmpty else { return }
        let directory = model.store.directory(for: sessionId)
        let duration = sessionDuration
        segments = VideoTimeline.segments(assets: assets, sessionStartUTC: manifest.startedAtUTC,
                                          sessionDuration: duration, syncOffset: syncOffset)
        gaps = VideoTimeline.gaps(segments: segments, sessionDuration: duration)
        if let composition = try? await VideoLibrary.buildComposition(
            segments: segments, sessionDirectory: directory, sessionDuration: duration) {
            let wasAt = currentT
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            if wasAt > 0.5 { seek(to: wasAt) }
        }
    }
}

// MARK: - Chart: always-zoomed rolling timeline, editor-style scrub

/// Video-editor timeline: the needle sits at the right edge, the visible
/// domain is the trailing `window` seconds, and nothing after "now" is drawn.
/// Playing slides the window; horizontally scrolling the chart pans time
/// (content follows the finger) and seeks the video, pausing playback.
private struct PlayheadChart: View {
    let series: MetricSeries
    let playhead: TimeInterval
    let window: TimeInterval
    let sessionDuration: TimeInterval
    let onScrubBegan: () -> Void
    let onScrub: (TimeInterval) -> Void
    let onScrubEnded: () -> Void

    @State private var dragStartT: TimeInterval?

    /// Window slice via binary search (cheap at frame rate), ending with a
    /// point interpolated at exactly `playhead` so the line meets the needle
    /// continuously instead of stepping sample-to-sample.
    private var visiblePoints: [SeriesPoint] {
        let source = series.finePoints.isEmpty ? series.points : series.finePoints
        guard !source.isEmpty else { return [] }
        let lo = lowerBound(source, playhead - window)
        let hi = lowerBound(source, playhead)
        var points = Array(source[lo..<hi])
        if hi > 0 {
            let a = source[hi - 1]
            if hi < source.count {
                let b = source[hi]
                if b.x > a.x, playhead >= a.x, playhead - a.x < 3 {
                    let f = (playhead - a.x) / (b.x - a.x)
                    points.append(SeriesPoint(x: playhead, y: a.y + (b.y - a.y) * f))
                }
            } else if playhead - a.x < 1 {
                points.append(SeriesPoint(x: playhead, y: a.y))
            }
        }
        return points
    }

    private func lowerBound(_ points: [SeriesPoint], _ x: Double) -> Int {
        var lo = 0
        var hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].x < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(series.unit)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.muted)
            }
            chart
        }
        .padding(12)
        .background(Color.cardGray, in: RoundedRectangle(cornerRadius: 14))
    }

    private var chart: some View {
        let points = visiblePoints
        return Chart {
            if series.symmetricZero {
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(points) { point in
                LineMark(x: .value("t", point.x), y: .value("v", point.y))
                    .foregroundStyle(series.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.catmullRom)
            }
            // The needle: current time, always visible at the right edge
            RuleMark(x: .value("now", playhead))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            if let last = points.last {
                PointMark(x: .value("t", last.x), y: .value("v", last.y))
                    .foregroundStyle(series.color)
                    .symbolSize(70)
            }
        }
        .chartXScale(domain: (playhead - window)...max(playhead, playhead - window + 0.5))
        .chartYScale(domain: series.yDomain)
        .transaction { $0.animation = nil } // frame-driven: no implicit tweening
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(label(seconds))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Color.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { drag in
                                let plotWidth = geo[proxy.plotFrame!].width
                                guard plotWidth > 0 else { return }
                                if dragStartT == nil {
                                    dragStartT = playhead
                                    onScrubBegan()
                                }
                                // Editor-style: content follows the finger —
                                // drag left = forward in time, right = back.
                                let dt = -drag.translation.width / plotWidth * window
                                let target = (dragStartT ?? playhead) + dt
                                onScrub(min(max(0, target), sessionDuration))
                            }
                            .onEnded { _ in
                                dragStartT = nil
                                onScrubEnded()
                            }
                    )
            }
        }
    }

    private func label(_ seconds: Double) -> String {
        guard seconds >= -0.01 else { return "" } // pre-session part of the window
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
