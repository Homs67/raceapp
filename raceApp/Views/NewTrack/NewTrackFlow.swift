//
//  NewTrackFlow.swift
//  raceApp
//
//  Making a track, full screen: name & type → where is it → place the
//  lines (TrackEditorView). Nothing is saved until the editor's Save, so
//  closing at any step leaves no half-made track behind.
//

import SwiftUI
import MapKit

struct NewTrackFlow: View {
    @Environment(\.dismiss) private var dismiss
    /// Called with the saved track after the cover closes.
    let onCreated: (Track) -> Void

    @State private var draft = Track.newUserTrack(name: "", kind: .circuit)
    @State private var path: [Step] = []

    private enum Step: Hashable {
        case location
        case lines(lat: Double, lon: Double)
    }

    var body: some View {
        NavigationStack(path: $path) {
            NewTrackNameView(name: $draft.name, kind: Binding(get: { draft.trackKind }, set: { setKind($0) }),
                             onClose: { dismiss() },
                             onNext: { path.append(.location) })
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .location:
                        TrackLocationView { place in
                            draft.location = place.locality
                            draft.country = place.country
                            path.append(.lines(lat: place.center.latitude, lon: place.center.longitude))
                        }
                    case .lines(let lat, let lon):
                        TrackEditorView(track: draft,
                                        region: MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                   latitudinalMeters: 250, longitudinalMeters: 250)) { saved in
                            dismiss()
                            onCreated(saved)
                        }
                    }
                }
        }
        .tint(Color.accent)
        .preferredColorScheme(.dark)
    }

    private func setKind(_ kind: Track.Kind) {
        draft.kind = kind
        draft.configuration = kind.title
    }
}

/// Step 1: what's it called and what kind of track is it.
struct NewTrackNameView: View {
    @Binding var name: String
    @Binding var kind: Track.Kind
    let onClose: () -> Void
    let onNext: () -> Void
    @FocusState private var editing: Bool

    private var placeholder: String {
        "\(kind.title) · \(Date().formatted(.dateTime.day().month(.abbreviated)))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 16)
            typeTile
            TextField("", text: $name, prompt: Text(placeholder).foregroundStyle(Color.mutedWeak))
                .font(.sofia(42, .bold))
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .focused($editing)
                .submitLabel(.next)
                .onSubmit(next)
                .padding(.horizontal, 16)
                .padding(.top, 30)
            Spacer(minLength: 16)
            kindToggle
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x0E0E0E))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { editing = true }
    }

    private var header: some View {
        ZStack {
            Text("New track").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.textPrimary)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color.editorRaised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Button(action: next) {
                    Text("Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var typeTile: some View {
        kindIcon(kind, color: .accent, size: 46, weight: 2.2)
            .frame(width: 96, height: 96)
            .background(Color.editorRaised, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .animation(.snappy, value: kind)
    }

    private var kindToggle: some View {
        HStack(spacing: 0) {
            ForEach(Track.Kind.allCases, id: \.self) { k in
                let on = k == kind
                Button { kind = k } label: {
                    HStack(spacing: 7) {
                        kindIcon(k, color: on ? .accent : .muted, size: 17, weight: 1.6)
                        Text(k.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? Color.white : Color.muted)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(on ? Color.editorSelected : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.editorRaised, in: Capsule())
        .animation(.snappy(duration: 0.2), value: kind)
    }

    @ViewBuilder private func kindIcon(_ k: Track.Kind, color: Color, size: CGFloat, weight: CGFloat) -> some View {
        if k == .circuit {
            CircuitGlyph()
                .stroke(color, style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else {
            Image(systemName: Track.Kind.pointToPointSymbol)
                .font(.system(size: size * 0.82, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }

    private func next() {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = placeholder }
        onNext()
    }
}
