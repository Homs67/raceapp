//
//  EmblemPlaygroundView.swift
//  raceApp
//
//  Debug ▸ Emblem playground: the live 3D emblem on top, every shape,
//  material, engraving and lighting value as a slider below. "Use in app"
//  saves the look for every emblem; "Copy" puts it on the clipboard as JSON.
//

import SwiftUI
import SceneKit

struct EmblemPlaygroundView: View {
    @Environment(AppModel.self) private var model
    @State private var style = EmblemScene.style
    @State private var trackId = "big-willow"
    @State private var color = Color(hex: 0xDF5313)
    @State private var locked = false
    @State private var version = 0
    @State private var flip = 0
    @State private var copied = false

    private var content: EmblemContent {
        let entry = AchievementCatalog.all.first { $0.trackId == trackId }
            ?? AchievementEntry(trackId: trackId, shortName: trackId, enamel: 0xDF5313)
        var e = entry
        e = AchievementEntry(trackId: e.trackId, shortName: e.shortName, enamel: UIColor(color).hexValue,
                             outlineTrackId: e.outlineTrackId, fullName: e.fullName, shape: e.shape)
        let progress = locked ? nil : AchievementProgress(earnedAt: Date(), bestLap: 104.39, laps: 1)
        let first = UserDefaults.standard.string(forKey: ProfileKeys.firstName) ?? ""
        return EmblemContent(entry: e, centerline: model.tracks.track(id: trackId)?.centerline ?? [],
                             progress: progress, driverName: first.isEmpty ? "Alex" : first)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaygroundEmblem(content: content, style: style, version: version, flip: flip)
                .frame(height: 320)
                .overlay(alignment: .bottomTrailing) {
                    Button { flip += 1 } label: {
                        Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(12)
                }
            Form {
                Section("Emblem") {
                    Picker("Track", selection: $trackId) {
                        ForEach(model.tracks.all.filter { $0.centerline.count > 2 }) { Text($0.name).tag($0.id) }
                    }
                    ColorPicker("Enamel colour", selection: $color, supportsOpacity: false)
                    Toggle("Locked (grey)", isOn: $locked)
                }
                Section("Shape") {
                    Toggle("Shape per track", isOn: $style.shapePerTrack)
                    Picker("Outline", selection: $style.shape) {
                        ForEach(EmblemShape.allCases) { Text($0.title).tag($0) }
                    }
                    slider("Thickness", $style.depth, 0.02...0.3)
                    slider("Face size (rim width)", $style.innerScale, 0.6...0.98)
                    slider("Outer corner rounding", $style.outerCorner, 0.01...0.4)
                    slider("Inner corner rounding", $style.innerCorner, 0.01...0.4)
                    slider("Rim edge rounding", $style.rimRounding, 0...0.04, step: 0.001)
                    slider("Inner lip width", $style.lipWidth, 0...0.08, step: 0.001)
                    slider("Inner lip height", $style.lipHeight, 0...0.08, step: 0.001)
                    slider("Front dome", $style.domeHeight, 0...0.25)
                    slider("Dome round ↔ hex", $style.domeHexness, 0...1)
                    slider("Back hollow", $style.dishDepth, 0...0.15)
                }
                Section("Track inlay") {
                    slider("Line width", $style.trackWidth, 0.01...0.1, step: 0.001)
                    slider("Line height", $style.trackHeight, 0...0.08, step: 0.001)
                    slider("Size", $style.trackScale, 0.4...1.4)
                    slider("Offset X", $style.trackOffsetX, -0.4...0.4)
                    slider("Offset Y", $style.trackOffsetY, -0.6...0.4)
                }
                Section("Track name on front") {
                    Toggle("Show name", isOn: $style.showFrontName)
                    slider("Text size", $style.frontNameSize, 0.04...0.2, step: 0.002)
                    slider("Position (up ↕ down)", $style.frontNameY, -0.8...0.7)
                    slider("Letter spacing", $style.frontNameSpacing, 0...0.5)
                    slider("Raised height", $style.frontNameHeight, 0...0.05, step: 0.001)
                    slider("Max width", $style.frontNameMaxWidth, 0.3...1)
                    Toggle("Bold", isOn: $style.frontNameBold)
                    Toggle("Condensed", isOn: $style.frontNameCondensed)
                }
                Section("Band") {
                    Toggle("Show band", isOn: $style.showBand)
                    slider("Band height", $style.bandHeight, -0.9...0.3)
                    slider("Band slope", $style.bandSlope, -0.8...0.8)
                    slider("Divider width", $style.dividerWidth, 0...0.06, step: 0.001)
                    slider("Divider height", $style.dividerHeight, 0...0.05, step: 0.001)
                }
                Section("Rim metal") {
                    slider("Brightness", $style.rimWhite, 0.1...1)
                    slider("Metalness", $style.rimMetalness, 0...1)
                    slider("Roughness", $style.rimRoughness, 0...1)
                }
                Section("Inlay metal (track, divider, lip)") {
                    slider("Brightness", $style.inlayWhite, 0.1...1)
                    slider("Metalness", $style.inlayMetalness, 0...1)
                    slider("Roughness", $style.inlayRoughness, 0...1)
                }
                Section("Enamel face") {
                    slider("Brightness", $style.enamelBrightness, 0.2...1.5)
                    slider("Metalness", $style.enamelMetalness, 0...1)
                    slider("Roughness", $style.enamelRoughness, 0...1)
                    slider("Glow", $style.enamelGlow, 0...1)
                    slider("Clear coat (gloss)", $style.enamelClearCoat, 0...1)
                }
                Section("Band metal") {
                    slider("Brightness", $style.bandWhite, 0.1...1)
                    slider("Metalness", $style.bandMetalness, 0...1)
                    slider("Roughness", $style.bandRoughness, 0...1)
                }
                Section("Back and engraving") {
                    slider("Brightness", $style.backWhite, 0.1...1)
                    slider("Metalness", $style.backMetalness, 0...1)
                    slider("Roughness", $style.backRoughness, 0...1)
                    slider("Engrave depth", $style.engraveDepth, 0...0.03, step: 0.001)
                    slider("Text size", $style.textSize, 0.04...0.12, step: 0.002)
                    slider("Letter spacing", $style.letterSpacing, 0...0.4)
                    slider("Metal vs letters contrast", $style.etchBase, 0.2...1)
                    Toggle("Bold text", isOn: $style.textBold)
                }
                Section("Lighting") {
                    slider("Reflections", $style.envIntensity, 0...3)
                    slider("Key light", $style.keyIntensity, 0...1500, step: 10)
                    slider("Light elevation", $style.keyElevation, -1.5...1.5)
                    slider("Light direction", $style.keyAzimuth, -3.1...3.1)
                    slider("Bloom", $style.bloom, 0...1)
                    Toggle("Shadows", isOn: $style.shadows)
                }
                Section {
                    Button("Use in app") {
                        style.save()
                        EmblemScene.style = style
                        EmblemThumbnailCache.images.removeAll()
                    }
                    Button(copied ? "Copied" : "Copy settings as JSON") {
                        UIPasteboard.general.string = style.json
                        copied = true
                    }
                    Button("Reset to defaults", role: .destructive) {
                        style = EmblemStyle()
                    }
                } footer: {
                    Text("Use in app saves this look for every emblem. Copy and paste the JSON into chat to make it the shipped default.")
                }
            }
        }
        .background(Color.bgScreen)
        .navigationTitle("Emblem playground")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.accent)
        // Rebuild once the sliders settle; the engraved back is a heavy mesh.
        .task(id: "\(trackId)-\(locked)-\(UIColor(color).hexValue)-\(style.json.hashValue)") {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            version += 1
            copied = false
        }
        .onDisappear { EmblemScene.style = .saved }
    }

    private func slider(_ title: String, _ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>,
                        step: CGFloat = 0.01) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 14))
                Spacer()
                Text(String(format: step < 0.01 ? "%.3f" : "%.2f", Double(value.wrappedValue)))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.muted)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

/// The live emblem, rebuilt when `version` changes, keeping its rotation.
private struct PlaygroundEmblem: UIViewRepresentable {
    let content: EmblemContent
    let style: EmblemStyle
    let version: Int
    let flip: Int

    func makeCoordinator() -> EmblemView.Coordinator { EmblemView.Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,
                                                         action: #selector(EmblemView.Coordinator.pan(_:))))
        rebuild(view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if context.coordinator.builtVersion != version { rebuild(view, context: context) }
        if context.coordinator.flipCount != flip {
            context.coordinator.flipCount = flip
            context.coordinator.flip()
        }
    }

    private func rebuild(_ view: SCNView, context: Context) {
        let angles = context.coordinator.medal?.eulerAngles ?? SCNVector3(0, 0, 0)
        EmblemScene.style = style
        let scene = EmblemScene.make(content)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        let medal = scene.rootNode.childNode(withName: "medal", recursively: false)
        medal?.eulerAngles = angles
        context.coordinator.medal = medal
        context.coordinator.builtVersion = version
    }
}
