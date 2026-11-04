//
//  TrackEditorView.swift
//  raceApp
//
//  Set a track's lines on a full-screen map, one line at a time:
//
//  - placing: a crosshair sits at the map center. "Place here" drops the
//    line there; "Mark where I stand" uses the RaceBox's position when it
//    is with you and has a fix (±0.3 m), otherwise the phone's (±3–5 m),
//    averaged over the last few seconds.
//  - editing: the placed line glows and a card offers Rotate, Direction
//    and Width. Cancel removes the line and goes back to placing.
//
//  A point-to-point course does the start, then Next, then the finish.
//  Saving re-times every session on this track. Design: Figma Track App,
//  "New track flow — iteration 2".
//

import SwiftUI
import MapKit
import CoreLocation
import SessionKit
import ObdKit

struct TrackEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Track
    @State private var phase: Phase
    @State private var tool: GateTool = .rotate
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D?
    @State private var satellite = true
    /// Lines flipped with the Direction tool since they were placed (point-to-point).
    @State private var reversed: Set<Which> = []
    @State private var live = LivePosition()
    @State private var compass = Compass()
    /// The new-track flow takes over after saving; on its own the editor pops.
    private let onSaved: ((Track) -> Void)?

    enum Which: Hashable { case start, finish }

    enum Phase: Equatable {
        case placing(Which)
        case editing(Which)

        var which: Which {
            switch self {
            case .placing(let w), .editing(let w): return w
            }
        }
    }

    /// - Parameters:
    ///   - region: where to open the map when the track has no lines yet
    ///     (the location step of the new-track flow).
    init(track: Track, region: MKCoordinateRegion? = nil, onSaved: ((Track) -> Void)? = nil) {
        _draft = State(initialValue: track)
        _phase = State(initialValue: track.startGate == nil ? .placing(.start) : .editing(.start))
        self.onSaved = onSaved
        let anchor = track.startGate.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            ?? track.anchor
        if let anchor {
            _camera = State(initialValue: .region(MKCoordinateRegion(center: anchor, latitudinalMeters: 160, longitudinalMeters: 160)))
        } else if let region {
            _camera = State(initialValue: .region(region))
        } else {
            _camera = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    private var isPointToPoint: Bool { draft.trackKind == .autocross }
    private var gate: TimingGate? { gate(phase.which) }
    private var defaultWidth: Double { isPointToPoint ? 15 : 25 }

    private func gate(_ which: Which) -> TimingGate? {
        which == .start ? draft.startGate : draft.finishGate
    }

    var body: some View {
        ZStack {
            map
            // Centred on the full-bleed map, not the safe area: "Place here"
            // drops the line at the map's own center.
            if case .placing = phase {
                MapCrosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                card
                    .padding(.bottom, 8)
            }
        }
        .background(Color.bgScreen)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .animation(.snappy(duration: 0.25), value: phase)
        .onAppear { live.start(model: model); compass.start() }
        .onDisappear { live.stop(); compass.stop() }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if draft.centerline.count > 2 {
                MapPolyline(coordinates: draft.centerlineCoordinates).stroke(.white.opacity(0.35), lineWidth: 2)
            }
            if let g = draft.startGate {
                GateMapContent(gate: g, color: .green, label: isPointToPoint ? "Start" : "Start/finish",
                               selected: phase == .editing(.start), onTap: { select(.start) })
            }
            if isPointToPoint, let g = draft.finishGate {
                GateMapContent(gate: g, color: .white, label: "Finish",
                               selected: phase == .editing(.finish), onTap: { select(.finish) })
            }
            if let here = live.coordinate {
                Annotation("", coordinate: here) {
                    Circle().fill(Color.accent).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(satellite ? .imagery(elevation: .flat)
                  : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { }
        .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            MapGlassButton(symbol: "chevron.left") { dismiss() }
                .accessibilityLabel("Back")
            Spacer()
            MapTitleCapsule(title: draft.name, subtitle: subtitle)
            Spacer()
            Menu {
                Picker("Map", selection: $satellite) {
                    Label("Satellite", systemImage: "globe.americas").tag(true)
                    Label("Standard", systemImage: "map").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                MapGlassLabel(symbol: "square.3.layers.3d")
            }
            .accessibilityLabel("Map style")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var subtitle: String {
        if isPointToPoint {
            return phase.which == .start ? "Step 1 of 2 · Start" : "Step 2 of 2 · Finish"
        }
        return gate == nil ? "Start/finish not set" : "Editing start/finish"
    }

    // MARK: Cards

    @ViewBuilder private var card: some View {
        switch phase {
        case .placing(let which):
            PlacingCard(title: "Place the \(lineName(which))",
                        subtitle: "Move the map so the cross sits on the \(which == .finish ? "finish" : isPointToPoint ? "start" : "line"), or stand on it and use your position.",
                        onBack: which == .finish && draft.startGate != nil ? { select(.start) } : nil,
                        onPlace: { placeAtCrosshair(which) },
                        markDetail: markDetail,
                        markEnabled: live.averaged != nil,
                        onMark: { markHere(which) })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .editing(let which):
            GateToolCard(title: "Edit \(isPointToPoint ? lineName(which) : "start/finish")",
                         onCancel: { remove(which) },
                         trailing: trailingAction(which),
                         tool: $tool) {
                toolControl(which)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func lineName(_ which: Which) -> String {
        guard isPointToPoint else { return "start/finish line" }
        return which == .start ? "start line" : "finish line"
    }

    private var markDetail: (text: String, symbol: String) {
        guard let acc = live.accuracy else { return ("Waiting for a position", "location.slash") }
        let device = live.source == .raceBox ? "RaceBox" : "iPhone"
        let meters = acc < 1 ? String(format: "%.1f", acc) : String(Int(acc.rounded()))
        return ("\(device) · ±\(meters) m", live.source == .raceBox ? "antenna.radiowaves.left.and.right" : "iphone")
    }

    /// Circuit: Save. Point-to-point: Next after the start, Save after the finish.
    private func trailingAction(_ which: Which) -> (label: String, enabled: Bool, action: () -> Void) {
        if isPointToPoint && which == .start {
            return ("Next", true, { select(.finish) })
        }
        let complete = draft.startGate != nil && (!isPointToPoint || draft.finishGate != nil)
        return ("Save", complete, save)
    }

    @ViewBuilder private func toolControl(_ which: Which) -> some View {
        switch tool {
        case .rotate:
            RotationDial(degrees: Binding(get: { gate?.headingDegrees ?? 0 }, set: { setHeading($0) }))
        case .direction:
            DirectionTiles(labels: isPointToPoint ? ("Forward", "Reverse") : ("Clockwise", "Counter-clockwise"),
                           reversed: isReversed(which)) { setReversed($0, which) }
        case .width:
            WidthStepper(meters: Binding(get: { gate?.widthMeters ?? defaultWidth },
                                         set: { w in update { $0.widthMeters = w } }))
        }
    }

    // MARK: Editing

    private func select(_ which: Which) {
        phase = gate(which) == nil ? .placing(which) : .editing(which)
    }

    private func placeAtCrosshair(_ which: Which) {
        guard let c = center else { return }
        place(at: c, heading: nil, which)
    }

    private func markHere(_ which: Which) {
        guard let c = live.averaged else { return }
        place(at: c, heading: compass.heading, which)
    }

    private func place(at c: CLLocationCoordinate2D, heading: Double?, _ which: Which) {
        let existing = gate(which)
        let h = heading ?? existing?.headingDegrees ?? suggestedHeading(from: c, which)
        let g = TimingGate(lat: c.latitude, lon: c.longitude, headingDegrees: h,
                           widthMeters: existing?.widthMeters ?? defaultWidth)
        if which == .start { draft.startGate = g } else { draft.finishGate = g }
        reversed.remove(which)
        tool = .rotate
        phase = .editing(which)
    }

    /// A finish aims along the line from the start. Anything else points up
    /// the screen (the map doesn't rotate here), so the line lies flat.
    private func suggestedHeading(from c: CLLocationCoordinate2D, _ which: Which) -> Double {
        if which == .finish, let s = draft.startGate {
            return Track.bearing([s.lat, s.lon], [c.latitude, c.longitude])
        }
        return 0
    }

    /// Cancel: the line goes, and you place it again.
    private func remove(_ which: Which) {
        if which == .start { draft.startGate = nil } else { draft.finishGate = nil }
        reversed.remove(which)
        phase = .placing(which)
    }

    private func isReversed(_ which: Which) -> Bool {
        isPointToPoint ? reversed.contains(which) : draft.direction == "counterclockwise"
    }

    private func setReversed(_ on: Bool, _ which: Which) {
        guard on != isReversed(which) else { return }
        update { $0.headingDegrees = ($0.headingDegrees + 180).truncatingRemainder(dividingBy: 360) }
        if isPointToPoint {
            if on { reversed.insert(which) } else { reversed.remove(which) }
        } else {
            draft.direction = on ? "counterclockwise" : "clockwise"
        }
    }

    private func update(_ change: (inout TimingGate) -> Void) {
        if phase.which == .start, var g = draft.startGate { change(&g); draft.startGate = g }
        if phase.which == .finish, var g = draft.finishGate { change(&g); draft.finishGate = g }
    }

    private func setHeading(_ h: Double) {
        update { $0.headingDegrees = (h + 360).truncatingRemainder(dividingBy: 360) }
    }

    private func save() {
        model.tracks.save(draft)
        let saved = model.tracks.track(id: draft.id) ?? draft
        model.trackDidChange(saved)
        if let onSaved { onSaved(saved) } else { dismiss() }
    }
}

// MARK: - Live position for marking

/// Where you are standing, from the RaceBox when it has a fix, else the phone.
/// Both land in gps.* on the bus; the source is whoever owns position.
@MainActor @Observable
final class LivePosition {
    enum Source { case raceBox, phone }
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var averaged: CLLocationCoordinate2D?
    private(set) var accuracy: Double?
    private(set) var source: Source = .phone
    private var samples: [(t: TimeInterval, c: CLLocationCoordinate2D)] = []
    private var task: Task<Void, Never>?

    func start(model: AppModel) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(model)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func tick(_ model: AppModel) {
        let snap = model.bus.snapshot()
        let now = monotonicNow()
        source = model.raceBox.ownsMotion ? .raceBox : .phone
        // Someone standing still on a line gets few new fixes — iOS slows
        // location updates when the phone doesn't move — so a fix stays
        // usable for 30 s rather than the dashboard's few seconds.
        guard let latR = snap[.gpsLatitude], let lonR = snap[.gpsLongitude], now - latR.t < 30 else {
            coordinate = nil; averaged = nil; accuracy = nil; samples.removeAll()
            return
        }
        let c = CLLocationCoordinate2D(latitude: latR.value, longitude: lonR.value)
        coordinate = c
        accuracy = snap[.gpsHorizontalAccuracy].flatMap { now - $0.t < 30 ? $0.value : nil }
        // Average the distinct fixes of the last 3 s: someone standing on a
        // line wobbles a little, and phone GPS more than that.
        if samples.last?.t != latR.t { samples.append((latR.t, c)) }
        samples.removeAll { latR.t - $0.t > 3 }
        let n = Double(samples.count)
        averaged = CLLocationCoordinate2D(latitude: samples.reduce(0) { $0 + $1.c.latitude } / n,
                                          longitude: samples.reduce(0) { $0 + $1.c.longitude } / n)
    }
}

/// Phone compass, for "point the phone the way cars will drive".
@MainActor @Observable
final class Compass: NSObject, CLLocationManagerDelegate {
    private(set) var heading: Double?
    private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        manager.headingFilter = 2
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() { manager.stopUpdatingHeading() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.heading = h }
    }
}
