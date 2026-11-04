//
//  SessionCard.swift
//  raceApp
//
//  Sessions list card (Figma Track-App "Session Card / Map", option 2):
//  date, place, track, duration and distance on the left; a faded map of
//  the drive on the right whose left, top and bottom edges dissolve into
//  the card.
//
//  - With a track the place name keeps to one line; without one it may wrap
//    to two.
//  - The map is a muted dark Apple Maps snapshot, greyscale at 30%, with the
//    route in accent. A session with a position but no usable route (a few
//    fixes, standing still) shows the map around it with a dot; one with
//    no position at all shows no map.
//  - Snapshots are cached on disk per session. The route is projected by us,
//    not by the snapshot, so it still draws when the map can't load offline.
//

import SwiftUI
import MapKit
import SessionKit
import ObdKit

struct SessionCard: View {
    @Environment(AppModel.self) private var model
    let session: SessionManifest
    let metric: Bool

    /// Text column width in the design (370 pt card, 16 pt padding).
    private static let textInsetTrailing: CGFloat = 370 - 16 - 214

    private var trackRef: SessionManifest.TrackRef? {
        guard let ref = session.track, !ref.id.isEmpty else { return nil }
        return ref
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            SessionMapThumb(session: session, directory: model.store.directory(for: session.id))
                .frame(width: SessionThumbnail.size.width)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.eyebrow(session.startedAtUTC))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(Color.muted)
                    Text(session.locationName ?? "Session")
                        .font(.sofia(22, .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(trackRef == nil ? 2 : 1)
                        .truncationMode(.tail)
                    if let trackRef { trackLine(trackRef) }
                }
                Spacer(minLength: 6)
                stats
            }
            .padding(.top, 15)
            .padding(.bottom, 14)
            .padding(.leading, 16)
            .padding(.trailing, Self.textInsetTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 128)
        .background(Color.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func trackLine(_ ref: SessionManifest.TrackRef) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.pattern.checkered")
                .font(.system(size: 9, weight: .medium))
            Text(ref.nameSnapshot)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.accent)
    }

    /// The track's own kind when it's still in the library; otherwise its
    /// layout: a separate finish line is a point-to-point course.
    private func isAutocross(_ ref: SessionManifest.TrackRef) -> Bool {
        if let track = model.tracks.track(id: ref.id) { return track.trackKind == .autocross }
        return ref.layout?.finish != nil
    }

    private var stats: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            statIcon("stopwatch")
            Spacer().frame(width: 4)
            Text(Self.duration(session.highlights?.durationSeconds ?? 0))
                .font(.sofiaNumeral(16, .bold))
                .foregroundStyle(Color(hex: 0xF5F5F5))
            Spacer().frame(width: 14)
            // On a circuit the distance is laps of it; elsewhere it's a route.
            if let trackRef, !isAutocross(trackRef) {
                CircuitGlyph()
                    .stroke(Color.muted, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                    // Sit the outline's bottom edge on the text baseline.
                    .alignmentGuide(.firstTextBaseline) { $0.height * 19.6 / 24 }
            } else {
                statIcon("point.topleft.down.to.point.bottomright.curvepath")
            }
            Spacer().frame(width: 4)
            Text(distanceValue)
                .font(.sofiaNumeral(16, .bold))
                .foregroundStyle(Color(hex: 0xF5F5F5))
            Spacer().frame(width: 3)
            Text(UnitsFormatter(metric: metric).distanceUnit)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.muted)
        }
        .lineLimit(1)
    }

    private func statIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.muted)
    }

    private var distanceValue: String {
        let units = UnitsFormatter(metric: metric)
        return String(format: "%.1f", units.distance(fromMeters: session.highlights?.distanceMeters ?? 0))
    }

    /// "OCT 27 · 1:32 PM"; the year joins in for sessions from another year.
    static func eyebrow(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = date.formatted(sameYear ? .dateTime.month(.abbreviated).day()
                                          : .dateTime.month(.abbreviated).day().year())
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)".uppercased()
    }

    /// 12:04, or 1:30:32 from an hour on.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Circuit glyph

/// Generic circuit outline for circuit tracks ("Valley and hill"), drawn on
/// a 24 pt grid in SF Symbols style.
struct CircuitGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        path.move(to: p(4, 16))
        path.addLine(to: p(4, 7))
        path.addCurve(to: p(8, 6.8), control1: p(4, 4.5), control2: p(7.6, 4.2))
        path.addLine(to: p(8.8, 11))
        path.addCurve(to: p(11.8, 11.2), control1: p(9.2, 13.1), control2: p(11, 13.1))
        path.addLine(to: p(12.8, 8.9))
        path.addCurve(to: p(16.2, 9), control1: p(13.6, 7), control2: p(15.6, 7.2))
        path.addLine(to: p(17.6, 12.6))
        path.addCurve(to: p(19.6, 15), control1: p(18, 13.6), control2: p(18.8, 14.3))
        path.addCurve(to: p(18.4, 19), control1: p(21, 16.2), control2: p(20.4, 19))
        path.addLine(to: p(7, 19))
        path.addCurve(to: p(4, 16), control1: p(5.3, 19), control2: p(4, 17.7))
        path.closeSubpath()
        return path
    }
}

// MARK: - Map thumbnail

private struct SessionMapThumb: View {
    let session: SessionManifest
    let directory: URL
    @State private var thumb: SessionThumbnail?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = thumb?.map {
                Image(uiImage: image)
                    .resizable()
                    .grayscale(1)
                    .opacity(0.3)
            }
            if let route = thumb?.route, route.count > 1 {
                routeLayer(route)
            } else if thumb != nil {
                // Only a position: the map is centred on it.
                Circle().fill(Color.accent)
                    .overlay(Circle().stroke(.white, lineWidth: 1.1))
                    .frame(width: 7.5, height: 7.5)
                    .position(x: SessionThumbnail.size.width / 2, y: SessionThumbnail.size.height / 2)
            }
        }
        .frame(width: SessionThumbnail.size.width, height: SessionThumbnail.size.height)
        // Left edge dissolves into the text; top and bottom into the card.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .clear, location: 0.12),
                                   .init(color: .black, location: 0.52),
                                   .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.18),
                                           .init(color: .black, location: 0.82),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: session.id) {
            thumb = await SessionThumbnails.shared.thumbnail(for: session, directory: directory)
        }
    }

    private func routeLayer(_ route: [CGPoint]) -> some View {
        ZStack(alignment: .topLeading) {
            Path { $0.addLines(route) }
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            if let start = route.first {
                Circle().fill(.white)
                    .frame(width: 7.5, height: 7.5)
                    .position(start)
            }
            if let finish = route.last {
                Circle().fill(Color.accent)
                    .overlay(Circle().stroke(.white, lineWidth: 1.1))
                    .frame(width: 7.5, height: 7.5)
                    .position(finish)
            }
        }
    }
}

/// A session's map: the snapshot (nil until loaded, or offline) and the
/// route in the thumbnail's points (empty when there's only a position).
nonisolated struct SessionThumbnail: Sendable {
    static let size = CGSize(width: 180, height: 128)
    /// Room kept around the route, so the line clears the faded edges.
    static let routeInsets = (x: CGFloat(23), y: CGFloat(13))

    var map: UIImage?
    var route: [CGPoint]
}

@MainActor
final class SessionThumbnails {
    static let shared = SessionThumbnails()

    private var memory: [UUID: SessionThumbnail] = [:]
    private var inFlight: [UUID: Task<SessionThumbnail?, Never>] = [:]
    /// Snapshots run one at a time so a long list doesn't fire dozens at once.
    private var tail: Task<Void, Never>?
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("session-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func thumbnail(for session: SessionManifest, directory sessionDir: URL) async -> SessionThumbnail? {
        if let hit = memory[session.id] { return hit }
        if let running = inFlight[session.id] { return await running.value }

        let id = session.id
        let cacheable = !session.isLive
        let files = (map: directory.appendingPathComponent("\(id)-v2.png"),
                     route: directory.appendingPathComponent("\(id)-v2.json"))
        let previous = tail
        let task = Task<SessionThumbnail?, Never> {
            _ = await previous?.value
            return await Self.make(sessionDirectory: sessionDir, files: files, cache: cacheable)
        }
        tail = Task { _ = await task.value }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        // Keep a thumbnail without its map out of memory, so the next
        // appearance retries the snapshot (offline at first, say).
        if let result, result.map != nil || !cacheable { memory[id] = result }
        return result
    }

    func remove(_ id: UUID) {
        memory[id] = nil
        for ext in ["png", "json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id)-v2.\(ext)"))
        }
    }

    private nonisolated struct Stored: Codable, Sendable {
        var route: [[Double]]
        /// Set when there is a position but no route.
        var located: Bool
    }

    private static func make(sessionDirectory: URL, files: (map: URL, route: URL),
                             cache: Bool) async -> SessionThumbnail? {
        // Route from disk, else from the GPS channels.
        let framing: Framing?
        if let data = try? Data(contentsOf: files.route),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            framing = Framing(stored: stored)
        } else {
            framing = await Task.detached { Framing.compute(sessionDirectory: sessionDirectory) }.value
            if cache, let framing, let data = try? JSONEncoder().encode(framing.stored) {
                try? data.write(to: files.route, options: .atomic)
            }
        }
        guard let framing else { return nil }

        if let data = try? Data(contentsOf: files.map), let image = UIImage(data: data, scale: 3) {
            return SessionThumbnail(map: image, route: framing.route)
        }
        let options = MKMapSnapshotter.Options()
        options.mapRect = framing.mapRect
        options.size = SessionThumbnail.size
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = 3
        }
        let image = try? await MKMapSnapshotter(options: options).start().image
        if cache, let png = image?.pngData() {
            try? png.write(to: files.map, options: .atomic)
        }
        return SessionThumbnail(map: image, route: framing.route)
    }

    /// Which part of the world the thumbnail shows, and the route in it.
    private nonisolated struct Framing {
        var mapRect: MKMapRect
        var route: [CGPoint]
        var stored: Stored

        init(mapRect: MKMapRect, route: [CGPoint], stored: Stored) {
            self.mapRect = mapRect
            self.route = route
            self.stored = stored
        }

        init?(stored: Stored) {
            let coords = stored.route.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            guard let f = Framing.frame(coords, located: stored.located) else { return nil }
            self = f
        }

        nonisolated static func compute(sessionDirectory: URL) -> Framing? {
            let lats = ChannelReader.samples(for: .gpsLatitude, inSessionDirectory: sessionDirectory)
            let lons = ChannelReader.samples(for: .gpsLongitude, inSessionDirectory: sessionDirectory)
            let count = min(lats.count, lons.count)
            // Keep the longest stretch without an impossible jump: a stale
            // first fix (the Simulator's default, a cold GPS) would otherwise
            // frame half a state around the drive.
            var best = 0..<0, runStart = 0
            for i in 0..<count {
                if i > 0 {
                    let a = CLLocation(latitude: lats[i - 1].value, longitude: lons[i - 1].value)
                    let b = CLLocation(latitude: lats[i].value, longitude: lons[i].value)
                    let dt = max(lats[i].t - lats[i - 1].t, 0.04)
                    if b.distance(from: a) / dt > 120 { runStart = i }
                }
                if i + 1 - runStart > best.count { best = runStart..<(i + 1) }
            }
            func coord(_ i: Int) -> CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: lats[i].value, longitude: lons[i].value)
            }
            let valid = best.filter {
                let c = coord($0)
                return CLLocationCoordinate2DIsValid(c) && abs(c.latitude) + abs(c.longitude) > 0.001
            }
            guard let firstIndex = valid.first else { return nil }
            // Thin by distance, not by sample: skipping samples on a lapping
            // drive joins points from different laps into chords across the
            // infield. Spacing ~1/150 of the drive's extent, coarser for very
            // long drives so a card never draws more than a few thousand points.
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            var travelled = 0.0, prev = MKMapPoint(coord(firstIndex))
            for i in valid {
                let m = MKMapPoint(coord(i))
                minX = min(minX, m.x); maxX = max(maxX, m.x); minY = min(minY, m.y); maxY = max(maxY, m.y)
                travelled += prev.distance(to: m); prev = m
            }
            let perMeter = MKMapPointsPerMeterAtLatitude(coord(firstIndex).latitude)
            let spacing = max(max(maxX - minX, maxY - minY) / perMeter / 150, travelled / 3000)
            var coords = [coord(firstIndex)]
            var kept = MKMapPoint(coord(firstIndex))
            for i in valid {
                let m = MKMapPoint(coord(i))
                if kept.distance(to: m) >= spacing { coords.append(coord(i)); kept = m }
            }
            if let lastIndex = valid.last, lastIndex != firstIndex { coords.append(coord(lastIndex)) }
            guard let last = coords.last else { return nil }
            // A route that stays within a few tens of metres isn't one to draw.
            let points = coords.map(MKMapPoint.init)
            let xs = points.map(\.x), ys = points.map(\.y)
            let extent = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) / MKMapPointsPerMeterAtLatitude(last.latitude)
            if coords.count < 3 || extent < 30 {
                return frame([last], located: true)
            }
            return frame(coords, located: false)
        }

        nonisolated static func frame(_ coords: [CLLocationCoordinate2D], located: Bool) -> Framing? {
            guard let first = coords.first else { return nil }
            let size = SessionThumbnail.size
            let perMeter = MKMapPointsPerMeterAtLatitude(first.latitude)
            let points = coords.map(MKMapPoint.init)
            let xs = points.map(\.x), ys = points.map(\.y)
            let center = MKMapPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
            let scale: Double   // map points per screen point
            if located {
                scale = 900 * perMeter / size.width
            } else {
                let inner = (w: size.width - 2 * SessionThumbnail.routeInsets.x,
                             h: size.height - 2 * SessionThumbnail.routeInsets.y)
                let fit = max((xs.max()! - xs.min()!) / inner.w, (ys.max()! - ys.min()!) / inner.h)
                scale = max(fit, 250 * perMeter / inner.w)
            }
            let rect = MKMapRect(x: center.x - scale * size.width / 2, y: center.y - scale * size.height / 2,
                                 width: scale * size.width, height: scale * size.height)
            let route = located ? [] : points.map {
                CGPoint(x: ($0.x - rect.origin.x) / scale, y: ($0.y - rect.origin.y) / scale)
            }
            return Framing(mapRect: rect, route: route,
                           stored: Stored(route: coords.map { [$0.latitude, $0.longitude] }, located: located))
        }
    }
}
