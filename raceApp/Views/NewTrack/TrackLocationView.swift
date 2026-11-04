//
//  TrackLocationView.swift
//  raceApp
//
//  Step 2 of a new track: where is it? A search sheet over the map:
//  "Use my location", tracks nearby, or native place search. Picking a
//  place only decides where the line editor opens; it places nothing.
//

import SwiftUI
import MapKit
import CoreLocation

/// Where the new track is, as picked in the location step.
struct TrackPlace {
    var center: CLLocationCoordinate2D
    var locality: String
    var country: String
}

struct TrackLocationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (TrackPlace) -> Void

    @State private var search = LocationSearch()
    @State private var here = OneShotLocation()
    @State private var query = ""
    @State private var resolving = false
    @FocusState private var searching: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Map(initialPosition: .userLocation(fallback: .automatic)) { UserAnnotation() }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls { }
                .ignoresSafeArea()
            HStack {
                MapGlassButton(symbol: "chevron.left") { dismiss() }
                    .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(searching ? 0 : 1)
            VStack(spacing: 0) {
                Spacer(minLength: searching ? 0 : 200)
                sheet
            }
        }
        .background(Color.bgScreen)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.snappy(duration: 0.25), value: searching)
        .onAppear { here.request() }
        .onChange(of: query) { _, q in search.query = q }
        .onChange(of: here.coordinate?.latitude) { _, _ in search.bias(to: here.coordinate) }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity).padding(.top, 7)
            if !searching {
                Text("Where is it?").font(.sofia(28, .bold)).foregroundStyle(Color.textPrimary)
                    .padding(.top, 18)
                Text("We\u{2019}ll open the map there so you can place the line.")
                    .font(.system(size: 13)).foregroundStyle(Color.muted)
                    .padding(.top, 2)
            }
            searchField.padding(.top, searching ? 14 : 16)
            useMyLocation.padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty { nearbyTracks } else { results }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.editorCard, in: UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
                TextField("Search a track, city or address", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .foregroundStyle(Color.textPrimary)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.muted) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Color.editorRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if searching {
                Button("Cancel") { query = ""; searching = false }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accent)
            }
        }
    }

    private var useMyLocation: some View {
        Button {
            guard let c = here.coordinate else { here.request(); return }
            onPick(TrackPlace(center: c, locality: here.locality ?? "", country: here.country ?? ""))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use my location").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.textPrimary)
                    Text(here.summary).font(.system(size: 13)).foregroundStyle(Color.mutedStrong)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Lists

    private var nearby: [(track: Track, meters: Double?)] {
        let all = model.tracks.all.compactMap { t -> (Track, CLLocationCoordinate2D)? in t.anchor.map { (t, $0) } }
        guard let c = here.coordinate else { return all.prefix(5).map { ($0.0, nil) } }
        let me = CLLocation(latitude: c.latitude, longitude: c.longitude)
        return all.map { ($0.0, me.distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))) }
            .filter { $0.1 < 50_000 }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
            .map { ($0.0, $0.1) }
    }

    @ViewBuilder private var nearbyTracks: some View {
        let list = nearby
        if !list.isEmpty {
            sectionTitle(here.coordinate == nil ? "Tracks" : "Nearby tracks")
            ForEach(list, id: \.track.id) { item in
                row(symbol: item.track.trackKind == .autocross ? Track.Kind.pointToPointSymbol : "flag.checkered",
                    title: Text(item.track.name), subtitle: item.track.location,
                    trailing: item.meters.map(distanceText)) {
                    if let c = item.track.anchor {
                        onPick(TrackPlace(center: c, locality: item.track.location, country: item.track.country))
                    }
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        ForEach(Array(search.results.enumerated()), id: \.offset) { _, completion in
            row(symbol: "mappin", title: highlighted(completion.title, completion.titleHighlightRanges),
                subtitle: completion.subtitle, trailing: nil) {
                Task { await pick(completion) }
            }
        }
        if search.results.isEmpty && !query.isEmpty {
            Text("No places found").font(.system(size: 14)).foregroundStyle(Color.muted).padding(.top, 20)
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response?.mapItems.first else { return }
        let p = item.placemark
        onPick(TrackPlace(center: p.coordinate,
                          locality: [p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: ", "),
                          country: p.country ?? ""))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 12, weight: .semibold)).kerning(0.9)
            .foregroundStyle(Color(hex: 0x8A8A8A))
            .padding(.top, 20).padding(.bottom, 4)
    }

    private func row(symbol: String, title: Text, subtitle: String, trailing: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(Color.editorRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: 16)).foregroundStyle(Color.textPrimary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
                    }
                }
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 13)).foregroundStyle(Color.muted)
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 52) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The completer's matched ranges in bold, as Maps does.
    private func highlighted(_ s: String, _ ranges: [NSValue]) -> Text {
        var a = AttributedString(s)
        for v in ranges {
            if let r = Range(v.rangeValue, in: s), let ar = Range(r, in: a) {
                a[ar].font = .system(size: 16, weight: .bold)
            }
        }
        return Text(a)
    }

    private func distanceText(_ meters: Double) -> String {
        let miles = meters / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : "\(Int(miles.rounded())) mi"
    }
}

// MARK: - Search and location

/// Native place autocomplete (the same engine as Maps), biased toward the user.
@MainActor @Observable
final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query = "" {
        didSet {
            if query.isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func bias(to c: CLLocationCoordinate2D?) {
        guard let c else { return }
        completer.region = MKCoordinateRegion(center: c, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { self.results = Array(completer.results.prefix(12)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.results = [] }
    }
}

/// One fix for "Use my location", plus its town for the subtitle.
@MainActor @Observable
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var locality: String?
    private(set) var country: String?
    private(set) var failed = false
    private let manager = CLLocationManager()

    var summary: String {
        if let locality { return "Near \(locality)" }
        if coordinate != nil { return "Current location" }
        return failed ? "Location unavailable" : "Finding you\u{2026}"
    }

    func request() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
            if let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
                self.locality = [p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: ", ")
                self.country = p.country
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.failed = self.coordinate == nil }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.requestLocation() }
        }
    }
}
