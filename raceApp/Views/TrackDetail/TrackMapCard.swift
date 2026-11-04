//
//  TrackMapCard.swift
//  raceApp
//
//  The track page's map: the session preview's drawn-map card, taller,
//  with the track in white, its corner numbers and line tags, an expand
//  button, and Navigate inside the card (Figma Track App → "A3 · Review
//  fixes").
//

import SwiftUI
import MapKit

struct TrackMapCard: View {
    let track: Track
    let stats: TrackStats?
    let directory: URL?
    let onExpand: () -> Void

    var body: some View {
        MapCard {
            TrackShapeView(track: track, bestRun: stats?.bestRun, directory: directory, style: .page)
                .padding(.top, 8)
                .padding(.bottom, 72)   // clear of the Navigate pill
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onExpand) { MapCardExpandIcon() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open map full screen")
                }
                Spacer()
                if let anchor = track.anchor {
                    NavigateButton(name: track.name, coordinate: anchor)
                }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 16)
        }
        .frame(height: 456)
    }
}

/// Orange "Navigate" pill, sized to its label: driving directions in Maps.
struct NavigateButton: View {
    let name: String
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill").font(.system(size: 15, weight: .semibold))
                Text("Navigate").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.leading, 22).padding(.trailing, 24)
            .frame(height: 48)
            .background(Color.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func open() {
        let item: MKMapItem
        if #available(iOS 26, *) {
            item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}
