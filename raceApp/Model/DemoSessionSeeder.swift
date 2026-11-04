//
//  DemoSessionSeeder.swift
//  raceApp
//
//  DEBUG: writes three finished track sessions — Laguna Seca, Big Willow and
//  the Streets of Willow — on different days with different drivers, through
//  the same store and channel files a real recording produces. Each is a pit
//  launch, an out lap, timed laps at their own pace, a partial in lap and a
//  stop, so the summary, lap bars, drag card and track map all have real
//  shape to show. Launch with `-seed-demo-sessions` (add `-reseed` to replace).
//

#if DEBUG
import Foundation
import SessionKit
import ObdKit

enum DemoSessionSeeder {

    /// How one driver drives.
    struct Driver {
        var name: String
        var paces: [Double]          // one per timed lap, fraction of the physics limit
        var outPace = 0.6
        var inPace = 0.5
        var grip = 1.0
        var maxBrakeG = 1.0
        var launchG: Double          // pit-exit launch
        var lineWobble: Double       // metres the line drifts lap to lap
        var brakePeak: Double        // % pedal at the hardest stop
        var brakeGain: Double        // % pedal per g of deceleration
        var stabbyThrottle: Bool     // all-or-nothing instead of progressive
        var noise: Double            // sensor + driver jitter, g
    }

    struct Event {
        var id: UUID
        var trackId: String
        var date: String             // ISO-8601 with offset, local track time
        var driver: Driver
        var ambientC: Double
        var elevationMeters: Double  // peak-to-peak climb around the lap
    }

    static let events: [Event] = [
        Event(id: UUID(uuidString: "D3E00000-0000-4000-8000-00000000A001")!, trackId: "laguna-seca",
              date: "2026-10-10T09:42:00-07:00",
              driver: Driver(name: "smooth", paces: [0.84, 0.86, 0.87, 0.875, 0.87, 0.88, 0.872, 0.866],
                             launchG: 0.3, lineWobble: 0.6, brakePeak: 72, brakeGain: 78,
                             stabbyThrottle: false, noise: 0.02),
              ambientC: 16, elevationMeters: 55),
        Event(id: UUID(uuidString: "D3E00000-0000-4000-8000-00000000A002")!, trackId: "big-willow",
              date: "2026-10-18T13:12:00-07:00",
              driver: Driver(name: "aggressive", paces: [0.9, 0.93, 0.95, 0.86, 0.96, 0.94],
                             outPace: 0.7, grip: 1.05, maxBrakeG: 1.1,
                             launchG: 0.52, lineWobble: 1.6, brakePeak: 96, brakeGain: 100,
                             stabbyThrottle: true, noise: 0.05),
              ambientC: 27, elevationMeters: 22),
        Event(id: UUID(uuidString: "D3E00000-0000-4000-8000-00000000A003")!, trackId: "streets-of-willow",
              date: "2026-10-24T15:20:00-07:00",
              driver: Driver(name: "learning", paces: [0.68, 0.72, 0.75, 0.78, 0.8, 0.82, 0.83, 0.85, 0.84, 0.86],
                             outPace: 0.55, inPace: 0.45, maxBrakeG: 0.8,
                             launchG: 0.24, lineWobble: 2.6, brakePeak: 48, brakeGain: 60,
                             stabbyThrottle: false, noise: 0.035),
              ambientC: 24, elevationMeters: 12),
    ]

    @MainActor
    static func runIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard args.contains("-seed-demo-sessions") else { return }
        let reseed = args.contains("-reseed")
        let store = model.store
        Task {
            for event in events {
                guard let track = model.tracks.track(id: event.trackId), track.centerline.count > 3 else { continue }
                let exists = (try? store.manifest(for: event.id)) != nil
                if exists, !reseed { continue }
                if exists { try? store.delete(event.id) }
                let centerline = track.centerline.map { GeoPoint(lat: $0[0], lon: $0[1]) }
                let name = track.name
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try await write(event, centerline: centerline, trackName: name, store: store)
                    }.value
                    model.setTrack(track, for: event.id)   // times the laps through the track's gate
                } catch {
                    print("[seed] \(event.trackId): \(error)")
                }
            }
            model.recording.sessionUpdated()
        }
    }

    // MARK: - One session

    /// The drive as samples at 25 Hz: (distance along the path, speed, lat G, long G).
    fileprivate struct Step { var dist: Double; var v: Double; var lat: Double; var lon: Double; var lap: Int }
    fileprivate static let dt = 0.04

    private static func write(_ event: Event, centerline: [GeoPoint], trackName: String, store: SessionStore,
                              labeled: Bool = true, title: String? = nil) async throws {
        let path = Path(centerline)
        let d = event.driver
        var rng = SplitMix(seed: withUnsafeBytes(of: event.id.uuid) { $0.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 } })
        func sim(_ pace: Double) -> TrackDriveSimulator {
            TrackDriveSimulator(centerline: centerline,
                                config: .init(pace: pace, grip: d.grip, maxBrakeG: d.maxBrakeG))
        }

        var steps: [Step] = []
        func hold(_ seconds: Double, at dist: Double) {
            for _ in 0..<Int(seconds / dt) { steps.append(Step(dist: dist, v: 0, lat: 0, lon: 0, lap: -1)) }
        }
        // Pit exit: a quarter of the way round, launch until the out-lap pace.
        let out = sim(d.outPace)
        let pitExit = path.length * 0.25
        var t0 = 0.0
        while t0 < out.lapTime, out.sample(atElapsed: t0).distance < pitExit { t0 += dt }
        let targetV = out.sample(atElapsed: t0).speedMps
        var v = 0.0, dist = pitExit - targetV * targetV / (2 * d.launchG * 9.81)
        dist = (dist + path.length).truncatingRemainder(dividingBy: path.length)
        hold(12, at: dist)
        while v < targetV {
            v = min(targetV, v + d.launchG * 9.81 * dt)
            dist += v * dt
            steps.append(Step(dist: dist, v: v, lat: 0, lon: d.launchG, lap: -1))
        }
        // Out lap from the pit exit to the line. The time left over at each line
        // carries into the next lap, so the 25 Hz clock stays even and no fix
        // lands exactly on the start/finish gate (where a crossing can't be seen).
        var t = t0
        while t < out.lapTime {
            let s = out.sample(atElapsed: t)
            steps.append(Step(dist: s.distance, v: s.speedMps, lat: s.lateralG, lon: s.longitudinalG, lap: -1))
            t += dt
        }
        var carry = max(0.007, t - out.lapTime)
        // Timed laps, each at its own pace.
        for (k, pace) in d.paces.enumerated() {
            let lap = sim(pace)
            t = carry
            while t < lap.lapTime {
                let s = lap.sample(atElapsed: t)
                steps.append(Step(dist: s.distance, v: s.speedMps, lat: s.lateralG, lon: s.longitudinalG, lap: k))
                t += dt
            }
            carry = max(0.007, t - lap.lapTime)
        }
        // In lap to the pit entry (60 % round), then roll to a stop.
        let inLap = sim(d.inPace)
        t = carry
        while t < inLap.lapTime, inLap.sample(atElapsed: t).distance < path.length * 0.6 {
            let s = inLap.sample(atElapsed: t)
            steps.append(Step(dist: s.distance, v: s.speedMps, lat: s.lateralG, lon: s.longitudinalG, lap: d.paces.count))
            t += dt
        }
        v = steps.last?.v ?? 0
        dist = steps.last?.dist ?? 0
        while v > 0 {
            v = max(0, v - 0.3 * 9.81 * dt)
            dist += v * dt
            steps.append(Step(dist: dist, v: v, lat: 0, lon: -0.3, lap: -1))
        }
        hold(10, at: dist)

        try await record(id: event.id, date: event.date, locationName: title ?? trackName,
                         note: labeled ? "Demo session · \(d.name) driver" : nil, driver: d, ambientC: event.ambientC,
                         altitude: { u in event.elevationMeters / 2 * (sin(2 * .pi * u - 0.6) + 0.35 * sin(4 * .pi * u)) },
                         steps: steps, path: path, store: store, rng: &rng)
    }

    /// Session files for a drive: every channel a real recording writes, from the same instant.
    fileprivate static func record(id: UUID, date: String, locationName: String, note: String?, driver d: Driver,
                                   ambientC: Double, altitude: (Double) -> Double, steps: [Step], path: Path,
                                   store: SessionStore, rng: inout SplitMix) async throws {
        let startUptime = 1_000.0
        let formatter = ISO8601DateFormatter()
        let started = formatter.date(from: date) ?? Date()
        var manifest = SessionManifest(id: id, startedAtUTC: started, startUptime: startUptime,
                                       status: .complete, appVersion: "demo",
                                       car: .init(make: "Mazda", model: "MX-5 ND2", vin: "JM1NDAD7XK0300000"))
        manifest.locationName = locationName
        manifest.note = note
        try store.create(manifest)
        let writer = try SessionWriter(sessionDirectory: store.directory(for: id))
        var highlights = HighlightsAccumulator()
        func put(_ id: ChannelId, _ value: Double, _ t: Double) async {
            await writer.append(id, value: value, at: t)
            highlights.add(channel: id, value: value, t: t)
        }

        let wheelbase = 2.31, steeringRatio = 15.9
        for (i, step) in steps.enumerated() {
            let t = startUptime + Double(i) * dt
            let u = step.dist / path.length
            // Line drift that changes slowly over the session, continuous across the line.
            let wobble = d.lineWobble * sin(2 * .pi * step.dist / 140) * cos(2 * .pi * Double(i) * dt / 317)
            let (p, heading) = path.point(at: step.dist, offsetMeters: wobble)
            let lat = step.lat + d.noise * rng.gaussian()
            let lon = step.lon + d.noise * rng.gaussian()
            await put(.gpsLatitude, p.lat, t)
            await put(.gpsLongitude, p.lon, t)
            await put(.gpsSpeed, max(0, step.v + 0.05 * rng.gaussian()), t)
            await put(.gpsCourse, heading, t)
            await put(.gpsHorizontalAccuracy, 0.5, t)
            await put(.carLatG, lat, t)
            await put(.carLongG, lon, t)

            // Driver inputs and engine, from the same instant.
            let obd = DemoDrive.derive(speedMps: step.v, longitudinalG: step.lon)
            await put(.canRpm, step.v < 0.5 ? 850 : obd.rpm, t)
            let throttle: Double
            if step.lon > 0.03 { throttle = d.stabbyThrottle ? 100 : min(100, 35 + step.lon * 140) }
            else if step.lon < -0.12 { throttle = 0 }
            else { throttle = abs(step.lat) > 0.5 ? 28 : 18 }
            await put(.canAccelPedal, max(0, min(100, throttle + 2 * rng.gaussian())), t)
            let brake = step.lon < -0.12 ? min(d.brakePeak, -step.lon * d.brakeGain) : 0
            await put(.canBrake, max(0, brake + (brake > 0 ? 1.5 * rng.gaussian() : 0)), t)
            let curvature = step.lat * 9.81 / max(step.v * step.v, 9)
            await put(.canSteering, atan(wheelbase * curvature) * 180 / .pi * steeringRatio + 1.5 * rng.gaussian(), t)

            if i % 5 == 0 {   // 5 Hz polled OBD + barometer
                await put(.obd(.speed), step.v * 3.6, t)
                await put(.obd(.engineLoad), min(100, 18 + throttle * 0.78), t)
                await put(.baroRelativeAltitude, altitude(u), t)
            }
            if i % 125 == 0 {  // the slow OBD sweep, every 5 s
                let warm = 1 - exp(-Double(i) * dt / 300)
                await put(.obd(.coolantTemp), 82 + 13 * warm + (d.stabbyThrottle ? 4 * warm : 0), t)
                await put(.obd(.ambientTemp), ambientC, t)
            }
        }
        let counts = await writer.close()
        let end = startUptime + Double(steps.count) * dt
        manifest.endedAtUTC = started.addingTimeInterval(end - startUptime)
        manifest.highlights = highlights.finalize(startUptime: startUptime, endUptime: end)
        manifest.channels = counts.map { SessionManifest.ChannelSummary(id: $0.key, sampleCount: $0.value) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        manifest.motionSourceSegments = [.init(source: .raceBox, start: startUptime, end: end)]
        try store.save(manifest)
    }

    // MARK: - Geometry

    /// A centerline, walkable by distance, with a sideways offset for the driven line.
    /// Closed by default (a circuit); an open one (a road) stops at its ends.
    fileprivate struct Path {
        let pts: [GeoPoint]
        let cum: [Double]
        let length: Double
        let closed: Bool
        private let mLat = 110_540.0
        private let mLon: Double

        init(_ pts: [GeoPoint], closed: Bool = true) {
            self.pts = pts
            self.closed = closed
            mLon = 111_320 * cos(pts[0].lat * .pi / 180)
            var c = [0.0]
            for i in 0..<(closed ? pts.count : pts.count - 1) {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                c.append(c[i] + hypot((b.lat - a.lat) * 110_540, (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180)))
            }
            cum = c
            length = c[c.count - 1]
        }

        /// Point at a distance along the loop, shifted right by `offsetMeters`, and the heading there.
        func point(at distance: Double, offsetMeters: Double) -> (GeoPoint, Double) {
            let s = closed ? (distance.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
                           : min(max(distance, 0), length - 1e-6)
            var lo = 0, hi = cum.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if cum[m] <= s { lo = m } else { hi = m } }
            let a = pts[lo], b = pts[(lo + 1) % pts.count]
            let seg = max(1e-6, cum[lo + 1] - cum[lo])
            let f = (s - cum[lo]) / seg
            let east = (b.lon - a.lon) * mLon, north = (b.lat - a.lat) * mLat
            let n = max(1e-6, hypot(east, north))
            // Right of travel is (north, -east) in (east, north) terms.
            let rx = north / n, ry = -east / n
            let p = GeoPoint(lat: a.lat + (b.lat - a.lat) * f + ry * offsetMeters / mLat,
                             lon: a.lon + (b.lon - a.lon) * f + rx * offsetMeters / mLon)
            let heading = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return (p, heading)
        }
    }

    /// Deterministic noise, so a reseed draws the same session.
    fileprivate struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u1 = max(1e-12, next()), u2 = next()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }
}
#endif

// MARK: - Presentation set

#if DEBUG
/// DEBUG: the data the talk's screenshots are taken with (`-seed-presentation`,
/// add `-reseed` to replace). The MX-5 in the garage; a session at Laguna Seca
/// and two at Big Willow (two emblems earned, the Streets still to drive); two
/// autocross courses marked in the app with a few runs each; and a canyon run
/// up the Angeles Crest. Nothing on ordinary streets.
extension DemoSessionSeeder {

    /// An autocross course: a loop around a lot, started from a stop at one end
    /// and finished a little short of the start.
    private struct Course {
        var trackId: String
        var name: String
        var location: String
        var center: GeoPoint
        var radii: (Double, Double)        // metres, east and north
        var wiggles: [(n: Double, amp: Double, phase: Double)]
        var rotation: Double              // degrees
        var finishFraction = 0.86
    }

    private static let courses: [Course] = [
        Course(trackId: "B0A70000-0000-4000-8000-0000000AC001", name: "Crows Landing Autocross",
               location: "Crows Landing, CA", center: GeoPoint(lat: 37.4095, lon: -121.1115),
               radii: (170, 95), wiggles: [(4, 0.16, 0.3), (7, 0.07, 1.1)], rotation: 18),
        Course(trackId: "B0A70000-0000-4000-8000-0000000AC002", name: "Marina Airport Autocross",
               location: "Marina, CA", center: GeoPoint(lat: 36.6810, lon: -121.7680),
               radii: (150, 80), wiggles: [(3, 0.14, 2.0), (6, 0.09, 0.4)], rotation: -32),
    ]

    private struct Outing {
        enum Place { case circuit(String), course(Int), canyon }
        var id: UUID
        var place: Place
        /// The session's own name; the track's name shows under it.
        var title: String
        var date: String
        var driver: Driver
        var ambientC: Double
    }

    private static let smooth = Driver(name: "smooth", paces: [0.84, 0.86, 0.87, 0.875, 0.87, 0.88, 0.872, 0.866],
                                       launchG: 0.3, lineWobble: 0.6, brakePeak: 72, brakeGain: 78,
                                       stabbyThrottle: false, noise: 0.02)
    private static let improving = Driver(name: "improving", paces: [0.8, 0.84, 0.87, 0.89, 0.9, 0.91],
                                          outPace: 0.62, launchG: 0.38, lineWobble: 1.1, brakePeak: 84,
                                          brakeGain: 88, stabbyThrottle: false, noise: 0.03)

    private static let outings: [Outing] = [
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0001")!, place: .course(0), title: "My First Autocross",
               date: "2026-08-23T10:05:00-07:00", driver: improving, ambientC: 29),
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0002")!, place: .canyon, title: "Angeles Crest Run",
               date: "2026-09-06T07:40:00-07:00", driver: smooth, ambientC: 17),
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0003")!, place: .course(1), title: "Autocross · Round 4",
               date: "2026-09-20T11:30:00-07:00", driver: improving, ambientC: 21),
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0004")!, place: .circuit("laguna-seca"), title: "Monterey Track Day",
               date: "2026-10-04T09:42:00-07:00", driver: smooth, ambientC: 16),
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0005")!, place: .circuit("big-willow"), title: "Willow Practice Day",
               date: "2026-10-17T10:15:00-07:00", driver: smooth, ambientC: 24),
        Outing(id: UUID(uuidString: "D3E00000-0000-4000-8000-0000000B0006")!, place: .circuit("big-willow"), title: "Big Willow Time Attack",
               date: "2026-10-18T13:12:00-07:00", driver: improving, ambientC: 27),
    ]

    @MainActor
    static func runPresentationIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard args.contains("-seed-presentation") else { return }
        let reseed = args.contains("-reseed")
        if model.garage.cars.isEmpty {
            let car = GarageCar(make: "Mazda", model: "MX-5", year: 2022, color: "Machine Grey", bundledPhoto: "CarMX5")
            Task { await model.garage.add(car, photo: nil) }
        }
        var courseTracks: [Track] = []
        for c in courses {
            let track = model.tracks.track(id: c.trackId) ?? makeTrack(c)
            if model.tracks.track(id: c.trackId) == nil { model.tracks.save(track) }
            courseTracks.append(track)
        }
        let store = model.store
        Task {
            for o in outings {
                let exists = (try? store.manifest(for: o.id)) != nil
                if exists, !reseed { continue }
                if exists { try? store.delete(o.id) }
                do {
                    switch o.place {
                    case .circuit(let id):
                        guard let track = model.tracks.track(id: id), track.centerline.count > 3 else { continue }
                        let event = Event(id: o.id, trackId: id, date: o.date, driver: o.driver, ambientC: o.ambientC,
                                          elevationMeters: id == "laguna-seca" ? 55 : 22)
                        let centerline = track.centerline.map { GeoPoint(lat: $0[0], lon: $0[1]) }
                        let name = track.name
                        try await Task.detached(priority: .userInitiated) {
                            try await write(event, centerline: centerline, trackName: name, store: store, labeled: false, title: o.title)
                        }.value
                        model.setTrack(track, for: o.id)
                    case .course(let k):
                        let c = courses[k]
                        try await Task.detached(priority: .userInitiated) {
                            try await writeAutocross(o, course: c, store: store)
                        }.value
                        model.setTrack(courseTracks[k], for: o.id)
                    case .canyon:
                        try await Task.detached(priority: .userInitiated) {
                            try await writeCanyon(o, store: store)
                        }.value
                    }
                } catch {
                    print("[seed] \(o.id): \(error)")
                }
            }
            model.recording.sessionUpdated()
        }
    }

    // MARK: Autocross

    private static func loop(_ c: Course) -> [GeoPoint] {
        let mLat = 110_540.0, mLon = 111_320 * cos(c.center.lat * .pi / 180)
        let rot = c.rotation * .pi / 180
        return (0..<360).map { i in
            let a = Double(i) / 360 * 2 * .pi
            let r = 1 + c.wiggles.reduce(0) { $0 + $1.amp * sin($1.n * a + $1.phase) }
            let x = c.radii.0 * r * cos(a), y = c.radii.1 * r * sin(a)
            let e = x * cos(rot) - y * sin(rot), n = x * sin(rot) + y * cos(rot)
            return GeoPoint(lat: c.center.lat + n / mLat, lon: c.center.lon + e / mLon)
        }
    }

    @MainActor
    private static func makeTrack(_ c: Course) -> Track {
        let path = Path(loop(c))
        func gate(at s: Double) -> TimingGate {
            let (p, heading) = path.point(at: s, offsetMeters: 0)
            return TimingGate(lat: p.lat, lon: p.lon, headingDegrees: heading, widthMeters: 16)
        }
        var t = Track.newUserTrack(name: c.name, kind: .autocross)
        t.id = c.trackId
        t.location = c.location
        t.country = "USA"
        t.startGate = gate(at: 5)
        t.finishGate = gate(at: path.length * c.finishFraction)
        t.lengthMeters = path.length * c.finishFraction - 5
        t.lengthMiles = t.lengthMeters / 1609.344
        t.createdAt = ISO8601DateFormatter().date(from: "2026-08-23T08:30:00-07:00")
        return t
    }

    private static func writeAutocross(_ o: Outing, course c: Course, store: SessionStore) async throws {
        let path = Path(loop(c))
        var rng = SplitMix(seed: withUnsafeBytes(of: o.id.uuid) { $0.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 } })
        var steps: [Step] = []
        let staging = -8.0, finish = path.length * c.finishFraction
        // Five runs, quicker each time, waiting in the grid between them.
        for (k, grip) in [0.78, 0.84, 0.88, 0.86, 0.92].enumerated() {
            steps += holdSteps(k == 0 ? 20 : 75, at: staging + path.length * Double(k))
            steps += profile(path, from: staging, to: path.length + staging, lap: k,
                             vmax: { $0 > finish ? 11 : 32 }, latG: grip, accelG: 0.42, brakeG: 0.95)
                .map { var s = $0; s.dist += path.length * Double(k); return s }
        }
        steps += holdSteps(15, at: steps.last?.dist ?? 0)
        try await record(id: o.id, date: o.date, locationName: o.title, note: nil,
                         driver: o.driver, ambientC: o.ambientC, altitude: { _ in 0 },
                         steps: steps, path: path, store: store, rng: &rng)
    }

    // MARK: Canyon

    /// Angeles Crest Highway from Clear Creek, about 13 km climbing east (OSM via OSRM).
    private static let canyonPolyline = #"uldpEhtcpU@s@Bi@Jw@NcA`@cCXkBL_AJkAR{BToBL}APkBPuANo@Pg@Ro@`@aAXu@Pe@Tq@Pi@Hk@D_@@c@Cy@Gg@YgAYu@c@oAcBeFOe@IWMc@Eg@?a@B]F]L[P[PQ\WZM^G^GZGRITOPSNWJWF[D[?]?k@?i@Bc@Ji@Li@Lc@Ri@R_@P[Va@Xa@Xe@Te@Vk@Xw@\_AZ}@b@mAb@qAX_APu@Jo@Dk@Be@@i@Ce@Gq@I_AI}@Ku@Io@Ci@?e@Dm@Jg@Rw@Rm@^kA\cAHUXaAHc@Fg@?_@Aa@Ic@Km@Ie@E_@?e@@YHq@Lg@Ng@R]RYZ_@b@e@^c@Xc@V_@P_@L_@Ni@Nw@N{@Ns@N}@Jq@N_AHm@Bm@@g@Ca@E_@Gc@Ie@Ga@Ce@@k@@e@Hg@Ha@LWTa@Ta@\a@XYZYX[VYR]Pa@Lm@Pw@TiAX_BZ}ARu@Pc@PYTSVMTMVMXSPQLWL]B[A]C]I]OYUOUKUCW?WDUJSPQVMZI^GZMb@MVOTg@d@[N{@^mAb@i@Lc@F[B[@]Cq@GgCYc@IWIYMWOYS[WYUYMWGWCUBg@Pa@d@Ql@EZ?Z@b@?`@?`@Ix@GZKXORSRYLYHYD[?UEWISOQQMUIm@A[@[D_@L[RW^a@^Y\[X[X[X_@T[Ta@Rc@N_@Le@Ng@Pm@Na@PWRUXOTKVEV?l@LZLb@Z`@\^X\VZL`@H`@B^@ZC\EZITITIPO`@g@Xc@^q@f@{@Xg@Zc@Zk@Rg@Lc@H_@B[C[G_@KWQSSQWMUGk@AW?c@B]@WEUGQMQQOUOYOa@Ma@I]E]Aa@D_@F[L]LYLWJYF[@[A[C_@G_@Ko@O}@Km@C]?a@B_@Te@b@]d@KV@j@ZRRj@p@\Z^NVBXATGXMVSTS\U\S^Kb@I^K\O`@Uz@m@jBqAdAq@r@k@b@]^]XYR]Ra@Hc@Dc@A]A[Ec@Ia@Ma@Wc@[[a@Sk@W_Ac@WM_@Qo@[a@[YWU[QYM[I[G]Ga@Ca@Em@Cu@Ai@Ga@Ic@K[M]QYSWi@Y]IYK[O[QWQa@W]Q]Ii@?YDWB]FYBU?WESIWOYUa@a@o@m@iBiBo@m@_@a@S]O[M[I]Gc@C_@Aa@@c@Fc@F_@H_@Ja@Je@Nq@Ho@Fg@@i@?_@Cc@Ag@Ei@Ii@G_@Oe@Ma@M]M_@E_@Ca@A_@B]F]J[L[P]Zg@`BiCj@{@Zi@Vg@Jc@D]?[A]CYI[M]KWQWYW[Uc@_@YYSUW[S[O[M[M]Ga@E_@Cg@?i@Bg@Da@Dc@@s@Ca@Ic@Mc@Q]USYSWUUUOYIYG[?_@?[D[F]La@Lg@Fi@Dc@A_@CYGWWi@WY[_@]_@UYMSUg@Gm@?[@a@Dc@@e@A_@CYG[IWKU_@e@c@UUI_@OYIg@U[YWc@Og@Go@?[@[@[F_@Fa@He@Jm@Hg@Fe@B[?q@Ik@IYWc@c@_@WQUOYQ]QUQSQ]e@MWIUGYE[Ec@A[?_@D_@H]J]Tg@l@cAv@oA^s@Tq@Tq@Ro@Pm@Pa@R]LY`@q@Xk@Pe@Ja@H]Dc@Fc@Bg@?e@Ae@Ck@Gk@Gg@Iu@Gi@Ci@Cu@?{@?yA?sAAmACk@E]E]K]Oc@s@cBi@mAOa@K_@Ia@Eg@CaAA]E_@G[Ss@OWSSSSUWSYKWIWI]Ee@GYIWMYQ]QSUQYMYIa@Ce@?a@A]C[IUMUUWi@Im@@[B[F]L]R]Zg@^k@N_@J]H_@@[?s@E[G]Ka@Wu@]sA]qASs@Mg@G_@Es@?_@DY"#

    private static func writeCanyon(_ o: Outing, store: SessionStore) async throws {
        let path = Path(decodePolyline(canyonPolyline), closed: false)
        var rng = SplitMix(seed: withUnsafeBytes(of: o.id.uuid) { $0.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 } })
        var steps = holdSteps(15, at: 0)
        steps += profile(path, from: 0, to: path.length, lap: -1, vmax: { _ in 27 }, latG: 0.62, accelG: 0.3, brakeG: 0.55)
        steps += holdSteps(15, at: path.length)
        try await record(id: o.id, date: o.date, locationName: o.title, note: nil,
                         driver: o.driver, ambientC: o.ambientC, altitude: { u in 640 * u },
                         steps: steps, path: path, store: store, rng: &rng)
    }

    // MARK: Driving a path

    private static func holdSteps(_ seconds: Double, at dist: Double) -> [Step] {
        Array(repeating: Step(dist: dist, v: 0, lat: 0, lon: 0, lap: -1), count: Int(seconds / dt))
    }

    /// From a stop at `from` to a stop at `to`: as fast as grip, the speed cap,
    /// the engine and the brakes allow, sampled at 25 Hz.
    private static func profile(_ path: Path, from: Double, to: Double, lap: Int, vmax: (Double) -> Double,
                                latG: Double, accelG: Double, brakeG: Double) -> [Step] {
        let ds = 1.0, n = Int((to - from) / ds) + 1
        // Curvature from the heading change over ±8 m.
        let headings = (0..<n).map { path.point(at: from + Double($0) * ds, offsetMeters: 0).1 * .pi / 180 }
        func turn(_ a: Double, _ b: Double) -> Double { atan2(sin(b - a), cos(b - a)) }
        let k: [Double] = (0..<n).map { i in
            let a = max(0, i - 8), b = min(n - 1, i + 8)
            return b > a ? turn(headings[a], headings[b]) / (Double(b - a) * ds) : 0
        }
        var v = (0..<n).map { i in min(vmax(from + Double(i) * ds), (latG * 9.81 / max(abs(k[i]), 1e-4)).squareRoot()) }
        v[0] = 0; v[n - 1] = 0
        for i in 1..<n { v[i] = min(v[i], (v[i - 1] * v[i - 1] + 2 * accelG * 9.81 * ds).squareRoot()) }
        for i in stride(from: n - 2, through: 0, by: -1) { v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * brakeG * 9.81 * ds).squareRoot()) }
        var out: [Step] = []
        var s = 0.0, last = 0.0
        while s < Double(n - 1) * ds {
            let i = min(n - 2, Int(s / ds)), f = s / ds - Double(i)
            // v² is linear in distance under constant acceleration; lerping v itself
            // would spike to ~2 g over the last metre of every stop.
            let speed = (v[i] * v[i] + (v[i + 1] * v[i + 1] - v[i] * v[i]) * f).squareRoot()
            let curv = k[i] + (k[i + 1] - k[i]) * f
            out.append(Step(dist: from + s, v: speed, lat: speed * speed * curv / 9.81,
                            lon: min(accelG, max(-brakeG, (speed - last) / dt / 9.81)), lap: lap))
            last = speed
            s += max(speed, 0.4) * dt
        }
        return out
    }

    /// Google's encoded polyline format, 1e-5 degrees.
    private static func decodePolyline(_ s: String) -> [GeoPoint] {
        var out: [GeoPoint] = []
        var lat = 0, lon = 0
        var it = s.utf8.makeIterator()
        func next() -> Int? {
            var result = 0, shift = 0
            while let c = it.next() {
                let b = Int(c) - 63
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while let dLat = next(), let dLon = next() {
            lat += dLat; lon += dLon
            out.append(GeoPoint(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }
}
#endif
