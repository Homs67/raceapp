//
//  TrackFullMapView.swift
//  raceApp
//
//  The track on a full-screen map. Only close, the name and the map-style
//  menu: no zoom buttons, recenter or toggle — pinch and drag do the rest.
//  Tap a corner number for its name.
//

import SwiftUI
import MapKit
import SessionKit

struct TrackFullMapView: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var satellite = true
    @State private var camera: MapCameraPosition
    @State private var selectedCorner: Int?

    init(track: Track) {
        self.track = track
        var pts = track.centerlineCoordinates
        for g in [track.layout?.start, track.layout?.finish].compactMap({ $0 }) {
            pts.append(CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon))
        }
        _camera = State(initialValue: .region(MapRegion.fitting(pts, minSpanMeters: 250)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                if track.centerline.count > 2 {
                    MapPolyline(coordinates: track.centerlineCoordinates)
                        .stroke(Color.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if let layout = track.layout {
                    GateMapContent(gate: layout.start, color: .green, label: layout.finish == nil ? "Start/finish" : "Start")
                    if let finish = layout.finish { GateMapContent(gate: finish, color: .white, label: "Finish") }
                }
                ForEach(track.corners) { c in
                    Annotation("", coordinate: c.coordinate, anchor: .center) { cornerBadge(c) }
                }
            }
            .mapStyle(satellite ? .imagery(elevation: .flat)
                      : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { }
            .ignoresSafeArea()

            HStack {
                MapGlassButton(symbol: "xmark") { dismiss() }
                    .accessibilityLabel("Close")
                Spacer()
                MapTitleCapsule(title: track.name)
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
        .background(Color.bgScreen)
    }

    private func cornerBadge(_ c: Track.Corner) -> some View {
        Button {
            selectedCorner = selectedCorner == c.n ? nil : c.n
        } label: {
            Text("\(c.n)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: 0x1F1F1F), in: Circle())
                .overlay(Circle().stroke(Color(hex: 0x3A3A3C), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if selectedCorner == c.n {
                Text(c.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize()
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .offset(y: -32)
            }
        }
        .accessibilityLabel("Turn \(c.n), \(c.name)")
    }
}
