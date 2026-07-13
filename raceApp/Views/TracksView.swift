//
//  TracksView.swift
//  raceApp
//
//  Browse the bundled track-map database: a list of tracks and a MapKit detail
//  showing the centerline, corners, and start/finish. Display-only — independent
//  of recording. Data + honesty caveats come from Track / TrackDatabase.
//

import SwiftUI
import MapKit
import CoreLocation

struct TracksView: View {
    @State private var path: [String] = TracksView.debugInitialPath()

    static func debugInitialPath() -> [String] {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-track-detail"),
           i + 1 < CommandLine.arguments.count {
            return [CommandLine.arguments[i + 1]]
        }
        #endif
        return []
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(TrackDatabase.all) { track in
                NavigationLink(value: track.id) {
                    TrackRow(track: track)
                }
            }
            .navigationTitle("Tracks")
            .navigationDestination(for: String.self) { id in
                if let track = TrackDatabase.track(id: id) {
                    TrackDetailView(track: track)
                }
            }
            .overlay {
                if TrackDatabase.all.isEmpty {
                    ContentUnavailableView("No Tracks", systemImage: "map",
                        description: Text("Track maps failed to load from the bundle."))
                }
            }
        }
    }
}

private struct TrackRow: View {
    let track: Track
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.name).font(.headline)
            Text(track.location).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(String(format: "%.2f mi", track.lengthMiles), systemImage: "ruler")
                Label("\(track.turnCount) turns", systemImage: "arrow.triangle.turn.up.right.diamond")
                Label(track.direction == "clockwise" ? "CW" : "CCW", systemImage: "arrow.clockwise")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TrackDetailView: View {
    let track: Track
    @State private var camera: MapCameraPosition
    @State private var showCorners = true

    init(track: Track) {
        self.track = track
        _camera = State(initialValue: .region(Self.region(for: track)))
    }

    var body: some View {
        Map(position: $camera) {
            // Centerline
            MapPolyline(coordinates: track.centerlineCoordinates)
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            // Start/finish gate
            MapPolyline(coordinates: [track.startFinish.pointA, track.startFinish.pointB])
                .stroke(.white, style: StrokeStyle(lineWidth: 4, dash: [2, 3]))
            // Corners
            if showCorners {
                ForEach(track.corners) { corner in
                    Annotation(corner.name, coordinate: corner.coordinate) {
                        ZStack {
                            Circle().fill(.black.opacity(0.6)).frame(width: 22, height: 22)
                            Text("\(corner.n)").font(.caption2.bold()).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .safeAreaInset(edge: .bottom) { statsBar }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCorners.toggle() } label: {
                    Image(systemName: showCorners ? "mappin.circle.fill" : "mappin.slash.circle")
                }
            }
        }
    }

    private var statsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                stat("\(track.configuration)", "Config")
                stat(String(format: "%.2f mi", track.lengthMiles), "Length")
                stat("\(track.turnCount)", "Turns")
            }
            if track.startFinish.approximate {
                Label("Start/finish approximate — pending on-track verification",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Map © OpenStreetMap contributors (ODbL)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A map region that frames the whole centerline with a margin.
    static func region(for track: Track) -> MKCoordinateRegion {
        let coords = track.centerlineCoordinates
        guard let first = coords.first else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                      span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
                                    longitudeDelta: (maxLon - minLon) * 1.4 + 0.001)
        return MKCoordinateRegion(center: center, span: span)
    }
}
