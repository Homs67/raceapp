//
//  TrackEditorView.swift
//  raceApp
//
//  Set a track's lines, two ways on one screen:
//
//  - on site: walk to the line, point the phone the way cars will drive,
//    tap Mark here. The position is the RaceBox's when it is with you and
//    has a fix (±0.3 m), otherwise the phone's (±3–5 m), averaged over the
//    last few seconds; the chip says which and how good.
//  - on the map: tap the satellite image where the line is.
//
//  Either way the line is then fine-tuned: rotate, flip, width. Saving
//  re-times every session on this track.
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
    @State private var editing: Which = .start
    @State private var camera: MapCameraPosition
    @State private var live = LivePosition()
    @State private var compass = Compass()

    enum Which: Hashable { case start, finish }

    init(track: Track) {
        _draft = State(initialValue: track)
        let anchor = track.startGate.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            ?? track.anchor
        _camera = State(initialValue: anchor.map {
            .region(MKCoordinateRegion(center: $0, latitudinalMeters: 160, longitudinalMeters: 160))
        } ?? .userLocation(fallback: .automatic))
    }

    private var isAutocross: Bool { draft.trackKind == .autocross }
    private var gate: TimingGate? { editing == .start ? draft.startGate : draft.finishGate }
    private var defaultWidth: Double { isAutocross ? 15 : 25 }

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $camera) {
                    if draft.centerline.count > 2 {
                        MapPolyline(coordinates: draft.centerlineCoordinates).stroke(.white.opacity(0.35), lineWidth: 2)
                    }
                    if let g = draft.startGate {
                        GateMapContent(gate: g, color: .green, label: isAutocross ? "Start" : "Start/finish")
                    }
                    if let g = draft.finishGate, isAutocross {
                        GateMapContent(gate: g, color: .white, label: "Finish")
                    }
                    if let here = live.coordinate {
                        Annotation("", coordinate: here) {
                            Circle().fill(Color.accent).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) {
                        place(at: c, heading: nil)
                    }
                }
            }
            controls
        }
        .background(Color.bgScreen)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.fontWeight(.semibold)
            }
        }
        .onAppear { live.start(model: model); compass.start() }
        .onDisappear { live.stop(); compass.stop() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isAutocross {
                Picker("Line", selection: $editing) {
                    Text("Start").tag(Which.start)
                    Text("Finish").tag(Which.finish)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                sourceChip
                Spacer()
                Button {
                    if let c = live.averaged { place(at: c, heading: compass.heading) }
                } label: {
                    Label("Mark here", systemImage: "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .disabled(live.averaged == nil)
            }

            if let gate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Direction \(Int(gate.headingDegrees.rounded()))°")
                            .font(.system(size: 13)).foregroundStyle(Color.muted)
                        Spacer()
                        Button { rotate(by: -5) } label: { Image(systemName: "rotate.left") }
                        Button { rotate(by: 5) } label: { Image(systemName: "rotate.right") }
                        Button { rotate(by: 180) } label: { Image(systemName: "arrow.up.arrow.down") }
                        if let h = compass.heading {
                            Button { setHeading(h) } label: { Image(systemName: "location.north.line") }
                        }
                    }
                    .buttonStyle(.bordered)
                    Slider(value: Binding(get: { gate.headingDegrees },
                                          set: { setHeading($0) }), in: 0...359, step: 1)
                    Stepper("Width \(Int(gate.widthMeters)) m", value: Binding(
                        get: { gate.widthMeters },
                        set: { w in update { $0.widthMeters = w } }), in: 4...60, step: 1)
                        .font(.system(size: 13))
                }
            } else {
                Text(editing == .start
                     ? "Stand on the start line, point the phone the way cars will go, and tap Mark here. Or tap the map."
                     : "Walk to the finish line and do the same. Or tap the map.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
            }
        }
        .padding(16)
        .background(Color.cardBg)
        .tint(Color.accent)
    }

    private var sourceChip: some View {
        HStack(spacing: 6) {
            Image(systemName: live.source == .raceBox ? "antenna.radiowaves.left.and.right" : "iphone")
            if let acc = live.accuracy {
                Text("\(live.source == .raceBox ? "RaceBox" : "iPhone") ±\(acc < 1 ? String(format: "%.1f", acc) : String(Int(acc.rounded()))) m")
            } else {
                Text("No position")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(live.accuracy == nil ? Color.muted : Color.textPrimary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    // MARK: Editing

    private func place(at c: CLLocationCoordinate2D, heading: Double?) {
        let existing = gate
        let h = heading ?? existing?.headingDegrees ?? suggestedHeading(from: c)
        let g = TimingGate(lat: c.latitude, lon: c.longitude, headingDegrees: h,
                           widthMeters: existing?.widthMeters ?? defaultWidth)
        if editing == .start { draft.startGate = g } else { draft.finishGate = g }
        // After placing the start of an autocross course, move on to the finish.
        if editing == .start, isAutocross, draft.finishGate == nil { editing = .finish }
    }

    /// With one line placed, aim a fresh one along the line between them.
    private func suggestedHeading(from c: CLLocationCoordinate2D) -> Double {
        if editing == .finish, let s = draft.startGate {
            return Track.bearing([s.lat, s.lon], [c.latitude, c.longitude])
        }
        return compass.heading ?? 0
    }

    private func update(_ change: (inout TimingGate) -> Void) {
        if editing == .start, var g = draft.startGate { change(&g); draft.startGate = g }
        if editing == .finish, var g = draft.finishGate { change(&g); draft.finishGate = g }
    }

    private func rotate(by degrees: Double) {
        update { $0.headingDegrees = ($0.headingDegrees + degrees + 360).truncatingRemainder(dividingBy: 360) }
    }

    private func setHeading(_ h: Double) {
        update { $0.headingDegrees = (h + 360).truncatingRemainder(dividingBy: 360) }
    }

    private func save() {
        model.tracks.save(draft)
        if let saved = model.tracks.track(id: draft.id) { model.trackDidChange(saved) }
        dismiss()
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
