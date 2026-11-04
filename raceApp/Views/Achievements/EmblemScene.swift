//
//  EmblemScene.swift
//  raceApp
//
//  The 3D track emblem, built in code with SceneKit (no model files): a
//  bevelled metal hexagon whose face bulges out like a coin pressed from
//  behind (the back is the matching hollow), the track outline raised in
//  polished metal on the dome, and a back with the lettering cut into it
//  ("EARNED BY ALEX · IN OCTOBER 2026 · BEST LAP 1:44.39"). Edges are sharp.
//  The name is under the emblem, not on it.
//
//  Metal only looks like metal when it has something to reflect, so the
//  scene carries a generated studio environment (dark room, a few soft
//  light strips); turning the emblem sweeps those highlights across it.
//
//  Locked emblems use the same geometry in flat grey.
//

import SceneKit
import SceneKit.ModelIO
import ModelIO
import SwiftUI
import UIKit

struct EmblemContent {
    var entry: AchievementEntry
    /// Track centerline as [lat, lon] pairs.
    var centerline: [[Double]]
    var progress: AchievementProgress?
    var driverName: String

    var locked: Bool { progress == nil }
}

enum EmblemScene {
    /// Vertex radius of the hexagon, in scene units.
    static let radius: CGFloat = 1
    /// Every tunable value; the debug playground edits it live.
    static var style = EmblemStyle.saved
    static var depth: CGFloat { style.depth }

    /// A scene whose root has one child, "medal", to rotate.
    /// `engraveBack: false` skips the finely meshed engraving (stills only
    /// show the front).
    static func make(_ content: EmblemContent, transparentBackground: Bool = false,
                     cameraDistance: Float = 4.5, engraveBack: Bool = true) -> SCNScene {
        // Each track's own outline, unless the playground says otherwise.
        let savedShape = style.shape
        if style.shapePerTrack { style.shape = content.entry.emblemShape }
        defer { style.shape = savedShape }
        let scene = SCNScene()
        scene.background.contents = transparentBackground ? UIColor.clear : UIColor.black
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = content.locked ? 0.7 : style.envIntensity

        let medal = SCNNode()
        medal.name = "medal"
        scene.rootNode.addChildNode(medal)

        let m = Materials(locked: content.locked, enamel: UIColor(hex: content.entry.enamel))
        let front = depth / 2

        // Rim: a bevelled hexagonal ring. The middle is open; the domed face
        // and the dished back fill it.
        prepareShape()
        let outer = outline(radius: radius, corner: style.outerCorner)
        let inner = innerOutline
        let ring = path(outer)
        ring.append(path(inner.reversed()))
        ring.usesEvenOddFillRule = true
        let rim = SCNShape(path: ring, extrusionDepth: depth)
        // A hairline round-over on the front and back edges: still crisp, but
        // the edges catch a thin line of light.
        rim.chamferRadius = style.rimRounding
        rim.chamferMode = style.rimRounding > 0 ? .both : .front
        rim.chamferProfile = { let p = UIBezierPath(); p.move(to: CGPoint(x: 0, y: 1))
            p.addQuadCurve(to: CGPoint(x: 1, y: 0), controlPoint: CGPoint(x: 0, y: 0)); return p }()
        rim.materials = [m.metal]
        medal.addChildNode(SCNNode(geometry: rim))

        // Inner lip: a hairline chrome step where the face meets the rim.
        if style.lipWidth > 0.001 {
            let lipInner = outline(radius: radius * (innerScale - style.lipWidth), corner: max(style.innerCorner - 0.01, 0))
            let lipPath = path(inner)
            lipPath.append(path(lipInner.reversed()))
            lipPath.usesEvenOddFillRule = true
            let lip = SCNShape(path: lipPath, extrusionDepth: style.lipHeight)
            lip.materials = [m.outline]
            let lipNode = SCNNode(geometry: lip)
            lipNode.position.z = Float(front)
            medal.addChildNode(lipNode)
        }

        // Face: enamel over most of it, a brushed-steel band below a diagonal
        // (one surface, the materials come from maps). Barely domed.
        medal.addChildNode(SCNNode(geometry: domeMesh(inner, base: front, height: domeHeight, facingFront: true,
                                                      material: m.face)))
        // Chrome inlay along the band's edge.
        let opening = path(outline(radius: radius * (innerScale - 0.02), corner: max(style.innerCorner - 0.01, 0))).cgPath
        let divider = style.showBand
            ? stride(from: -radius, through: radius, by: 0.01).map { CGPoint(x: $0, y: bandY($0)) }.filter { opening.contains($0) }
            : []
        if style.dividerWidth > 0.001, let line = bead(divider, width: style.dividerWidth, height: style.dividerHeight, closed: false,
                           z: { x, y in front + Self.domeOffset(x, y, height: domeHeight) }, material: m.outline) {
            medal.addChildNode(SCNNode(geometry: line))
        }
        // Back: the hollow, with the lines cut into it.
        var lines: [String] = []
        if let p = content.progress {
            let month = p.earnedAt.formatted(.dateTime.month(.wide).year()).uppercased()
            let who = content.driverName.trimmingCharacters(in: .whitespaces)
            lines = who.isEmpty ? ["EARNED IN", month] : ["EARNED BY \(who.uppercased())", "IN \(month)"]
            lines.append("BEST LAP \(RunFormat.time(p.bestLap))")
        }
        if engraveBack, !lines.isEmpty {
            // One fine mesh for the whole back, so the lettering has no seam round it.
            medal.addChildNode(SCNNode(geometry: engravedBack(lines, base: -front, material: m.back)))
        } else {
            medal.addChildNode(SCNNode(geometry: domeMesh(inner, base: -front, height: dishDepth, facingFront: false,
                                                          material: m.back)))
        }

        // Optional: the track's name on the face, raised chrome lettering
        // following the dome.
        if style.showFrontName {
            let label = text(content.entry.shortName.uppercased(), size: style.frontNameSize,
                             weight: style.frontNameBold ? .bold : .medium, material: m.outline,
                             width: Self.innerInradius * 1.5 * style.frontNameMaxWidth, depth: style.frontNameHeight,
                             fontWidth: style.frontNameCondensed ? .condensed : .standard,
                             tracking: style.frontNameSpacing)
            // Flat lettering resting on the face's highest point along its
            // line (the face is only slightly domed).
            let rest = Self.domeOffset(0, style.frontNameY, height: domeHeight)
            label.position = SCNVector3(0, Float(style.frontNameY), Float(front + rest + style.frontNameHeight / 2))
            medal.addChildNode(label)
        }

        // Track outline: a thin chrome inlay, nearly flush with the enamel.
        let apothem = Self.innerInradius
        let bw = apothem * 1.48 * style.trackScale, bh = apothem * 1.08 * style.trackScale
        let box = CGRect(x: style.trackOffsetX - bw / 2, y: style.trackOffsetY - bh / 2, width: bw, height: bh)
        if let outline = bead(trackPoints(content.centerline, in: box), width: style.trackWidth, height: style.trackHeight,
                              z: { x, y in front + Self.domeOffset(x, y, height: domeHeight) }, material: m.outline) {
            medal.addChildNode(SCNNode(geometry: outline))
        }

        // Camera and a soft key light; the environment does most of the work.
        let camera = SCNCamera()
        // Fit the width: the view is portrait, a vertical FOV crops the sides.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 34
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = content.locked ? 0 : style.bloom
        camera.bloomThreshold = 0.9
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = content.locked ? 250 : style.keyIntensity
        // The raised outline throws a soft shadow onto the dome.
        key.castsShadow = !content.locked && style.shadows
        key.shadowMode = .deferred
        key.shadowRadius = 4
        key.shadowSampleCount = 8
        key.shadowColor = UIColor(white: 0, alpha: 0.55)
        key.orthographicScale = 1.4
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(Float(-style.keyElevation), Float(style.keyAzimuth), 0)
        scene.rootNode.addChildNode(keyNode)
        return scene
    }

    /// A still of the emblem, for the grid (live scenes there would be too
    /// heavy). Slightly turned so the bevel reads.
    static func snapshot(_ content: EmblemContent, size: CGSize, yaw: Float = 0.32) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = make(content, transparentBackground: true, cameraDistance: 3.6, engraveBack: false)
        scene.rootNode.childNode(withName: "medal", recursively: false)?.eulerAngles = SCNVector3(0.06, yaw, 0)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    // MARK: Materials

    /// The band's top edge: a diagonal rising to the right across the
    /// lower part of the face.
    static func bandY(_ x: CGFloat) -> CGFloat { style.bandHeight + style.bandSlope * (x / radius) }

    /// Face maps (enamel above the diagonal, brushed steel below), laid over
    /// the face's square of side 2 × the opening radius.
    private static func faceMap(enamel: UIColor, band: UIColor) -> UIImage {
        let size = 512, r = radius * innerScale
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            enamel.setFill(); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            func px(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x + r) / (2 * r) * CGFloat(size), y: (1 - (y + r) / (2 * r)) * CGFloat(size))
            }
            let p = UIBezierPath()
            p.move(to: px(-r, bandY(-r))); p.addLine(to: px(r, bandY(r)))
            p.addLine(to: px(r, -r)); p.addLine(to: px(-r, -r)); p.close()
            if EmblemScene.style.showBand { band.setFill(); p.fill() }
        }
    }

    private struct Materials {
        let metal: SCNMaterial
        let outline: SCNMaterial
        let face: SCNMaterial
        let back: SCNMaterial
        let engrave: SCNMaterial

        init(locked: Bool, enamel color: UIColor) {
            func pbr(_ diffuse: Any, metal: Any, rough: Any) -> SCNMaterial {
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = diffuse
                m.metalness.contents = metal
                m.roughness.contents = rough
                return m
            }
            func gray(_ w: CGFloat) -> UIColor { UIColor(white: w, alpha: 1) }
            if locked {
                metal = pbr(gray(0.55), metal: 0.5, rough: 0.6)
                outline = pbr(gray(0.5), metal: 0.5, rough: 0.6)
                face = pbr(EmblemScene.faceMap(enamel: gray(0.30), band: gray(0.40)), metal: 0.3, rough: 0.6)
                back = pbr(gray(0.45), metal: 0.5, rough: 0.6)
                engrave = pbr(gray(0.62), metal: 0.3, rough: 0.7)
            } else {
                let st = EmblemScene.style
                // Rim, lip and inlays.
                metal = pbr(gray(st.rimWhite), metal: st.rimMetalness, rough: st.rimRoughness)
                outline = pbr(gray(st.inlayWhite), metal: st.inlayMetalness, rough: st.inlayRoughness)
                // Enamel face and the band (brushed steel by default).
                let f = pbr(EmblemScene.faceMap(enamel: color.blended(st.enamelBrightness), band: gray(st.bandWhite)),
                            metal: EmblemScene.faceMap(enamel: gray(st.enamelMetalness), band: gray(st.bandMetalness)),
                            rough: EmblemScene.faceMap(enamel: gray(st.enamelRoughness), band: gray(st.bandRoughness)))
                f.emission.contents = EmblemScene.faceMap(enamel: color.blended(st.enamelGlow), band: gray(0.06 * st.enamelGlow / 0.36))
                f.clearCoat.contents = st.enamelClearCoat
                f.clearCoatRoughness.contents = 0.05
                face = f
                // Back; the etching is lighter (vertex colours).
                back = pbr(gray(st.backWhite), metal: st.backMetalness, rough: st.backRoughness)
                engrave = pbr(gray(0.98), metal: 0.5, rough: 0.6)
            }
        }
    }

    // MARK: Dome

    /// Inner edge of the rim, as a share of the outer radius.
    static var innerScale: CGFloat { style.innerScale }
    /// How far the face bulges past the rim, and how deep the back is dished.
    static var domeHeight: CGFloat { style.domeHeight }
    static var dishDepth: CGFloat { style.dishDepth }
    /// How deep the lettering is cut into the back.
    static var engraveDepth: CGFloat { style.engraveDepth }
    /// The face's outline, its distance from the centre by angle (for the
    /// dome), and its smallest such distance. Set by `prepareShape()`.
    private(set) static var innerOutline: [CGPoint] = []
    private static var boundary: [CGFloat] = []
    private(set) static var innerInradius: CGFloat = 0.8

    /// Work out the face outline for the current style's shape.
    static func prepareShape() {
        innerOutline = outline(radius: radius * innerScale, corner: style.innerCorner)
        let pts = innerOutline, n = pts.count
        boundary = (0..<720).map { k -> CGFloat in
            let a = CGFloat(k) / 720 * 2 * .pi
            let d = CGPoint(x: cos(a), y: sin(a))
            var best: CGFloat = 0
            for i in 0..<n {
                let p = pts[i], q = pts[(i + 1) % n]
                // Ray from the origin along d against the segment p→q.
                let e = CGPoint(x: q.x - p.x, y: q.y - p.y)
                let den = d.x * e.y - d.y * e.x
                guard abs(den) > 1e-12 else { continue }
                let t = (p.x * e.y - p.y * e.x) / den
                let u = (p.x * d.y - p.y * d.x) / den
                if t > 0, u >= 0, u <= 1 { best = max(best, t) }
            }
            return max(best, 0.05)
        }
        innerInradius = boundary.min() ?? 0.8
    }

    /// Distance from the centre as a share of the way to the face's edge
    /// along that direction: 0 in the middle, 1 on the outline.
    static func shapeNorm(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let d = (x * x + y * y).squareRoot()
        guard d > 1e-9, !boundary.isEmpty else { return 0 }
        var a = atan2(y, x)
        if a < 0 { a += 2 * .pi }
        let f = a / (2 * .pi) * CGFloat(boundary.count)
        let i = Int(f) % boundary.count, j = (i + 1) % boundary.count, t = f - floor(f)
        return d / (boundary[i] * (1 - t) + boundary[j] * t)
    }

    /// Height of the dome above the rim at (x, y): 1 in the middle, 0 at the
    /// rim, a soft cushion profile in between.
    static func domeOffset(_ x: CGFloat, _ y: CGFloat, height: CGFloat) -> CGFloat {
        // Half round, half hexagonal distance from the centre: round in the
        // middle like a pressed coin, settling into the rim's shape at the edge
        // (pointy-top hexagon: edge normals at 0°, ±60°).
        // A soft maximum of the three edge directions (a 6-norm): taking the
        // plain max leaves a fold from the centre to every corner.
        let hex = shapeNorm(x, y)
        let round = (x * x + y * y).squareRoot() / innerInradius
        let k = style.domeHexness
        let s = min(1, k * hex + (1 - k) * round)
        // Cushion: flat-ish top, rolling off towards the rim.
        let c = 1 - s * s
        return height * c * (2 - c)
    }

    /// The domed (or dished) surface filling the rim: concentric rings of the
    /// inner outline, lifted by `domeOffset`, with averaged normals.
    private static func domeMesh(_ outline: [CGPoint], base: CGFloat, height: CGFloat, facingFront: Bool,
                                 material: SCNMaterial, hole: CGRect? = nil) -> SCNGeometry {
        let rings = 40
        var verts: [SCNVector3] = [SCNVector3(0, 0, Float(base + domeOffset(0, 0, height: height)))]
        for r in 1...rings {
            let t = CGFloat(r) / CGFloat(rings)
            for p in outline {
                // Ring scale t, height from the ring itself so the edge meets the rim exactly.
                let x = p.x * t, y = p.y * t
                verts.append(SCNVector3(Float(x), Float(y), Float(base + (r == rings ? 0 : domeOffset(x, y, height: height)))))
            }
        }
        let n = outline.count
        var idx: [Int32] = []
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            // Leave out what the engraved patch covers.
            if let hole, [a, b, c].allSatisfy({ hole.contains(CGPoint(x: CGFloat(verts[$0].x), y: CGFloat(verts[$0].y))) }) {
                return
            }
            if facingFront { idx += [Int32(a), Int32(b), Int32(c)] } else { idx += [Int32(a), Int32(c), Int32(b)] }
        }
        for i in 0..<n { tri(0, 1 + i, 1 + (i + 1) % n) }
        for r in 1..<rings {
            let a0 = 1 + (r - 1) * n, b0 = 1 + r * n
            for i in 0..<n {
                let j = (i + 1) % n
                tri(a0 + i, b0 + i, b0 + j)
                tri(a0 + i, b0 + j, a0 + j)
            }
        }
        // Normals from the surface itself, not averaged from the triangles:
        // the ring layout of the mesh would otherwise show as lines in the light.
        let e: CGFloat = 0.002
        let ns = verts.map { v -> SCNVector3 in
            let x = CGFloat(v.x), y = CGFloat(v.y)
            let dx = (domeOffset(x + e, y, height: height) - domeOffset(x - e, y, height: height)) / (2 * e)
            let dy = (domeOffset(x, y + e, height: height) - domeOffset(x, y - e, height: height)) / (2 * e)
            let n = facingFront ? simd_normalize(SIMD3<Float>(Float(-dx), Float(-dy), 1))
                                : simd_normalize(SIMD3<Float>(Float(dx), Float(dy), -1))
            return SCNVector3(n.x, n.y, n.z)
        }
        let r = radius * innerScale
        let uv = verts.map { CGPoint(x: (CGFloat($0.x) + r) / (2 * r), y: 1 - (CGFloat($0.y) + r) / (2 * r)) }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: ns),
                                      SCNGeometrySource(textureCoordinates: uv)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }

    /// Re-express a node's geometry in `parent`'s space and lift every vertex
    /// by `offset(x, y)`, so flat shapes (the outline, the engraving) follow
    /// the curved face.
    private static func bake(_ node: SCNNode, into parent: SCNNode, offset: (CGFloat, CGFloat) -> CGFloat) {
        guard var geometry = node.geometry else { return }
        // SCNShape and SCNText build their triangles lazily, at first render;
        // going through ModelIO makes them now.
        let materials = geometry.materials
        var attempts = 0
        while (geometry.sources(for: .vertex).first?.vectorCount ?? 0) == 0, attempts < 3, let shape = node.geometry {
            geometry = SCNGeometry(mdlMesh: MDLMesh(scnGeometry: shape))
            attempts += 1
        }
        geometry.materials = materials
        // Still nothing to bend: leave it flat rather than lose it.
        guard let vSource = geometry.sources(for: .vertex).first, vSource.vectorCount > 0 else { return }
        let verts = read(vSource).map { v -> SCNVector3 in
            var p = node.convertPosition(v, to: parent)
            p.z += Float(offset(CGFloat(p.x), CGFloat(p.y)))
            return p
        }
        var sources = [SCNGeometrySource(vertices: verts)]
        if let nSource = geometry.sources(for: .normal).first {
            sources.append(SCNGeometrySource(normals: read(nSource).map { node.convertVector($0, to: parent) }))
        }
        let baked = SCNGeometry(sources: sources, elements: geometry.elements)
        baked.materials = geometry.materials.isEmpty ? (node.geometry?.materials ?? []) : geometry.materials
        node.removeFromParentNode()
        parent.addChildNode(SCNNode(geometry: baked))
    }

    private static func read(_ source: SCNGeometrySource) -> [SCNVector3] {
        let stride = source.dataStride, offset = source.dataOffset
        let size = source.bytesPerComponent
        return source.data.withUnsafeBytes { raw -> [SCNVector3] in
            (0..<source.vectorCount).map { i in
                let base = i * stride + offset
                func c(_ k: Int) -> Float {
                    size == 8 ? Float(raw.load(fromByteOffset: base + k * 8, as: Double.self))
                              : raw.load(fromByteOffset: base + k * 4, as: Float.self)
                }
                return SCNVector3(c(0), c(1), c(2))
            }
        }
    }

    // MARK: Geometry helpers

    /// Pointy-top hexagon with rounded corners, as a closed polyline.
    /// The emblem's outline at vertex radius `r`, corners rounded by `corner`,
    /// always counter-clockwise (the face meshes are wound for that).
    static func outline(radius r: CGFloat, corner: CGFloat) -> [CGPoint] {
        let pts = rawOutline(radius: r, corner: corner)
        var area: CGFloat = 0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            area += p.x * q.y - q.x * p.y
        }
        return area < 0 ? pts.reversed() : pts
    }

    private static func rawOutline(radius r: CGFloat, corner: CGFloat) -> [CGPoint] {
        func regular(_ n: Int, _ start: CGFloat, sx: CGFloat = 1, sy: CGFloat = 1) -> [CGPoint] {
            (0..<n).map { i in
                let a = start + CGFloat(i) * 2 * .pi / CGFloat(n)
                return CGPoint(x: cos(a) * r * sx, y: sin(a) * r * sy)
            }
        }
        func star(_ points: Int, inner k: CGFloat) -> [CGPoint] {
            (0..<(points * 2)).map { i in
                let a = CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
                let rr = i.isMultiple(of: 2) ? r : r * k
                return CGPoint(x: cos(a) * rr, y: sin(a) * rr)
            }
        }
        switch style.shape {
        case .hexagon: return roundedPolygon(regular(6, .pi / 2), corner: corner)
        case .hexagonFlat: return roundedPolygon(regular(6, 0), corner: corner)
        case .circle: return regular(96, .pi / 2)
        case .square: return roundedPolygon(regular(4, .pi / 4, sx: 0.92, sy: 0.92), corner: corner * 1.4)
        case .diamond: return roundedPolygon(regular(4, .pi / 2, sx: 0.82), corner: corner)
        case .pentagon: return roundedPolygon(regular(5, .pi / 2), corner: corner)
        case .octagon: return roundedPolygon(regular(8, .pi / 8), corner: corner * 0.8)
        case .triangle: return roundedPolygon(regular(3, .pi / 2), corner: corner * 1.4)
        case .shield:
            // Flat top, straight sides, curving down to a point.
            var v = [CGPoint(x: -0.84, y: 0.84), CGPoint(x: 0.84, y: 0.84), CGPoint(x: 0.84, y: 0.05)]
            for i in 1..<8 {
                let t = CGFloat(i) / 8, a = t * .pi / 2
                v.append(CGPoint(x: 0.84 * cos(a), y: 0.05 - 1.0 * sin(a) * (0.6 + 0.4 * t)))
            }
            v.append(CGPoint(x: 0, y: -0.96))
            for i in (1..<8).reversed() {
                let t = CGFloat(i) / 8, a = t * .pi / 2
                v.append(CGPoint(x: -0.84 * cos(a), y: 0.05 - 1.0 * sin(a) * (0.6 + 0.4 * t)))
            }
            v.append(CGPoint(x: -0.84, y: 0.05))
            return roundedPolygon(v.map { CGPoint(x: $0.x * r, y: $0.y * r) }, corner: corner)
        case .star: return roundedPolygon(star(5, inner: 0.56), corner: corner * 0.5)
        case .badge: return roundedPolygon(star(12, inner: 0.86), corner: corner * 0.35)
        }
    }

    /// Kept for callers that want the classic shape regardless of style.
    static func roundedHexagon(radius r: CGFloat, corner: CGFloat) -> [CGPoint] {
        roundedPolygon((0..<6).map { i -> CGPoint in
            let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 3
            return CGPoint(x: cos(a) * r, y: sin(a) * r)
        }, corner: corner)
    }

    /// A polygon with each corner rounded off by up to `corner` along both
    /// edges (never past the middle of an edge).
    static func roundedPolygon(_ vertices: [CGPoint], corner: CGFloat) -> [CGPoint] {
        let n = vertices.count
        guard corner > 0.0005 else { return vertices }
        var out: [CGPoint] = []
        for i in 0..<n {
            let prev = vertices[(i + n - 1) % n], v = vertices[i], next = vertices[(i + 1) % n]
            let c = min(corner, 0.45 * dist(v, prev), 0.45 * dist(v, next))
            // Pull back along each edge by `c`, round between with a quad curve.
            let a = lerp(v, prev, c / dist(v, prev)), b = lerp(v, next, c / dist(v, next))
            for s in 0...6 {
                let t = CGFloat(s) / 6
                let p1 = lerp(a, v, t), p2 = lerp(v, b, t)
                out.append(lerp(p1, p2, t))
            }
        }
        return out
    }

    private static func path(_ pts: [CGPoint]) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: pts[0])
        pts.dropFirst().forEach { p.addLine(to: $0) }
        p.close()
        p.flatness = 0.002
        return p
    }

    private static func slab(_ pts: [CGPoint], depth: CGFloat, z: CGFloat, material: SCNMaterial) -> SCNNode {
        let shape = SCNShape(path: path(pts), extrusionDepth: depth)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.position.z = Float(z)
        return node
    }

    /// The part of a convex polygon below a horizontal line.
    private static func clip(_ poly: [CGPoint], below y: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let aIn = a.y <= y, bIn = b.y <= y
            if aIn { out.append(a) }
            if aIn != bIn {
                let t = (y - a.y) / (b.y - a.y)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: y))
            }
        }
        return out
    }

    private static func halfWidth(of poly: [CGPoint], at y: CGFloat) -> CGFloat {
        var xs: [CGFloat] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y - y) * (b.y - y) <= 0, a.y != b.y {
                xs.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y))
            }
        }
        return (xs.max() ?? 0)
    }

    /// The centerline fitted into `box` (scene units, y up), as a closed
    /// loop without its repeated end point.
    private static func trackPoints(_ centerline: [[Double]], in box: CGRect) -> [CGPoint] {
        guard centerline.count > 2 else { return [] }
        let k = cos(centerline[0][0] * .pi / 180)
        let raw = centerline.map { CGPoint(x: $0[1] * k, y: $0[0]) }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let s = min(box.width / max(maxX - minX, 1e-9), box.height / max(maxY - minY, 1e-9))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        var pts = raw.map { CGPoint(x: box.midX + ($0.x - cx) * s, y: box.midY + ($0.y - cy) * s) }
        pts = simplify(pts, tolerance: 0.0025)
        if pts.count > 2, dist(pts[0], pts[pts.count - 1]) < 0.02 { pts.removeLast() }
        return pts
    }

    /// A raised bar along a closed loop, `width` wide and `height` tall, with
    /// a flat top and straight sides (sharp edges), standing on the surface
    /// `z(x, y)`.
    private static func bead(_ pts: [CGPoint], width: CGFloat, height: CGFloat, closed: Bool = true,
                             z: (CGFloat, CGFloat) -> CGFloat, material: SCNMaterial) -> SCNGeometry? {
        let n = pts.count
        guard n > 2 else { return nil }
        var lb: [SIMD3<Float>] = [], lt: [SIMD3<Float>] = [], rt: [SIMD3<Float>] = [], rb: [SIMD3<Float>] = []
        for i in 0..<n {
            let prev = closed ? pts[(i + n - 1) % n] : pts[max(i - 1, 0)], cur = pts[i]
            let next = closed ? pts[(i + 1) % n] : pts[min(i + 1, n - 1)]
            func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                let dx = b.x - a.x, dy = b.y - a.y, l = max(hypot(dx, dy), 1e-9)
                return CGPoint(x: -dy / l, y: dx / l)
            }
            let n1 = normal(prev, cur), n2 = normal(cur, next)
            var m = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y)
            let ml = max(hypot(m.x, m.y), 1e-9)
            m = CGPoint(x: m.x / ml, y: m.y / ml)
            let half = width / 2 * min(1 / max(m.x * n2.x + m.y * n2.y, 0.35), 2.2)
            let l = CGPoint(x: cur.x - m.x * half, y: cur.y - m.y * half)
            let r = CGPoint(x: cur.x + m.x * half, y: cur.y + m.y * half)
            // Flat top: one height across the bar, from the higher foot.
            let top = max(z(l.x, l.y), z(r.x, r.y)) + height
            lb.append(SIMD3(Float(l.x), Float(l.y), Float(z(l.x, l.y) - 0.01)))
            rb.append(SIMD3(Float(r.x), Float(r.y), Float(z(r.x, r.y) - 0.01)))
            lt.append(SIMD3(Float(l.x), Float(l.y), Float(top)))
            rt.append(SIMD3(Float(r.x), Float(r.y), Float(top)))
        }
        // Each face is its own strip, so normals don't blend round the corners.
        var verts: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], idx: [Int32] = []
        func strip(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) {
            let o = verts.count
            for i in 0..<n { verts.append(a[i]); verts.append(b[i]) }
            var nrm = [SIMD3<Float>](repeating: .zero, count: 2 * n)
            for i in 0..<(closed ? n : n - 1) {
                let j = (i + 1) % n
                let q = [2 * i, 2 * j, 2 * j + 1, 2 * i, 2 * j + 1, 2 * i + 1]
                for t in stride(from: 0, to: 6, by: 3) {
                    let pa = verts[o + q[t]], pb = verts[o + q[t + 1]], pc = verts[o + q[t + 2]]
                    let f = simd_cross(pb - pa, pc - pa)
                    nrm[q[t]] += f; nrm[q[t + 1]] += f; nrm[q[t + 2]] += f
                }
                idx += q.map { Int32(o + $0) }
            }
            normals += nrm
        }
        strip(lt, rt)   // top
        strip(lb, lt)   // left side
        strip(rt, rb)   // right side
        // Wound the wrong way round (the loop ran clockwise): flip everything.
        if normals[0..<(2 * n)].reduce(Float(0), { $0 + $1.z }) < 0 {
            normals = normals.map { -$0 }
            for t in stride(from: 0, to: idx.count, by: 3) { idx.swapAt(t + 1, t + 2) }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts.map { SCNVector3($0.x, $0.y, $0.z) }),
                                      SCNGeometrySource(normals: normals.map { let u = simd_normalize($0); return SCNVector3(u.x, u.y, u.z) })],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }

    /// The whole back as one fine height map: the dish, with `lines` cut into
    /// it as grooves `engraveDepth` deep with steep walls and a darker floor,
    /// like letters cut into metal. Points past the rim's inner edge are pulled
    /// onto it, tucked just under the rim.
    private static func engravedBack(_ lines: [String], base: CGFloat, material: SCNMaterial) -> SCNGeometry {
        let step: CGFloat = 0.003
        let lineGap: CGFloat = style.textSize * 1.875, cap: CGFloat = style.textSize, maxWidth: CGFloat = 1.2
        let rect = CGRect(x: -radius * innerScale, y: -radius * innerScale,
                          width: 2 * radius * innerScale, height: 2 * radius * innerScale)
        let nx = Int(rect.width / step) + 1, ny = Int(rect.height / step) + 1

        // Rasterise the lines, one pixel per vertex. The back is seen from
        // behind, so the text is drawn mirrored left-right.
        var mask = [UInt8](repeating: 0, count: nx * ny)
        mask.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: nx, height: ny, bitsPerComponent: 8,
                                      bytesPerRow: nx, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldAntialias(true)
            ctx.translateBy(x: CGFloat(nx), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.setFillColor(gray: 1, alpha: 1)
            let capPx = cap / step
            for (i, text) in lines.enumerated() {
                var font = UIFont.systemFont(ofSize: 10, weight: style.textBold ? .semibold : .regular) as CTFont
                font = CTFontCreateCopyWithAttributes(font, 10 * capPx / CTFontGetCapHeight(font), nil, nil)
                var line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text, attributes: [.font: font, .foregroundColor: UIColor.white, .kern: capPx * style.letterSpacing]))
                var w = CTLineGetTypographicBounds(line, nil, nil, nil)
                if w > maxWidth / step {
                    let k = (maxWidth / step) / w
                    font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * k, nil, nil)
                    line = CTLineCreateWithAttributedString(NSAttributedString(
                        string: text, attributes: [.font: font, .foregroundColor: UIColor.white, .kern: capPx * style.letterSpacing]))
                    w = CTLineGetTypographicBounds(line, nil, nil, nil)
                }
                let centerY = (CGFloat(lines.count - 1) / 2 - CGFloat(i)) * lineGap
                let py = (centerY - rect.minY) / step - CTFontGetCapHeight(font) / 2
                ctx.textPosition = CGPoint(x: (CGFloat(nx) - w) / 2, y: py)
                CTLineDraw(line, ctx)
            }
        }
        // Memory rows run top-down; grid rows bottom-up.
        func m(_ ix: Int, _ iy: Int) -> CGFloat {
            CGFloat(mask[(ny - 1 - min(max(iy, 0), ny - 1)) * nx + min(max(ix, 0), nx - 1)]) / 255
        }
        // Surface height; into the metal is +z on the back.
        func h(_ ix: Int, _ iy: Int) -> CGFloat {
            let x = rect.minX + CGFloat(ix) * step, y = rect.minY + CGFloat(iy) * step
            return base + domeOffset(x, y, height: dishDepth) + engraveDepth * m(ix, iy)
        }
        // The rim's opening has rounded corners: anything outside it goes well
        // inside the rim, where the rim hides it.
        let opening = path(innerOutline).cgPath
        var verts: [SCNVector3] = [], normals: [SCNVector3] = [], colors: [SCNVector3] = []
        verts.reserveCapacity(nx * ny)
        for iy in 0..<ny {
            for ix in 0..<nx {
                var x = rect.minX + CGFloat(ix) * step, y = rect.minY + CGFloat(iy) * step
                var z = h(ix, iy)
                if !opening.contains(CGPoint(x: x, y: y)) {
                    let k = max(shapeNorm(x, y), 1)
                    x /= k; y /= k
                    z = base + 0.03
                }
                verts.append(SCNVector3(Float(x), Float(y), Float(z)))
                let dx = (h(ix + 1, iy) - h(ix - 1, iy)) / (2 * step)
                let dy = (h(ix, iy + 1) - h(ix, iy - 1)) / (2 * step)
                let n = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), -1))
                normals.append(SCNVector3(n.x, n.y, n.z))
                // The cut floor is darker, as cut metal reads.
                // Etched: the letters are lighter than the dark metal.
                let c = Float(style.etchBase + (1 - style.etchBase) * m(ix, iy))
                colors.append(SCNVector3(c, c, c))
            }
        }
        var idx: [Int32] = []
        idx.reserveCapacity((nx - 1) * (ny - 1) * 6)
        for iy in 0..<(ny - 1) {
            for ix in 0..<(nx - 1) {
                let a = Int32(iy * nx + ix), b = a + 1, c = a + Int32(nx), d = c + 1
                // Facing -z (the back).
                idx += [a, d, b, a, c, d]
            }
        }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals), colorSource],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }

    /// Ramer–Douglas–Peucker, so the outline triangulates quickly.
    private static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            let a = pts[lo], b = pts[hi]
            var best = (d: CGFloat(0), i: lo)
            for i in (lo + 1)..<hi {
                let d = distance(pts[i], toSegment: a, b)
                if d > best.d { best = (d, i) }
            }
            if best.d > tolerance {
                keep[best.i] = true
                stack.append((lo, best.i)); stack.append((best.i, hi))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func flipY(_ path: CGPath) -> CGPath {
        var t = CGAffineTransform(scaleX: 1, y: -1)
        return path.copy(using: &t) ?? path
    }

    /// Centered text, scaled to `size` cap height and squeezed to `width` at most.
    /// Centered text as an extruded shape built from the font's glyph
    /// outlines (unlike SCNText, a shape can be bent onto the curved back),
    /// `size` tall and squeezed to `width` at most.
    private static func text(_ string: String, size: CGFloat, weight: UIFont.Weight, material: SCNMaterial,
                             width maxWidth: CGFloat, depth: CGFloat = 0.012,
                             fontWidth: UIFont.Width = .condensed, tracking: CGFloat = 0) -> SCNNode {
        let font = UIFont.systemFont(ofSize: 40, weight: weight, width: fontWidth) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string, attributes: [.font: font, .kern: tracking * CTFontGetCapHeight(font)]))
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (g, p) in zip(ids, positions) {
                if let outline = CTFontCreatePathForGlyph(runFont, g, nil) {
                    glyphs.addPath(outline, transform: CGAffineTransform(translationX: p.x, y: p.y))
                }
            }
        }
        let bounds = glyphs.boundingBoxOfPath
        let scale = min(size / max(CTFontGetCapHeight(font), 1e-6), maxWidth / max(bounds.width, 1e-6))
        var t = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -CTFontGetCapHeight(font) / 2)
        // SF glyphs keep overlapping contours (it's a variable font); SceneKit
        // can't triangulate overlaps and silently drops those letters.
        let path = (glyphs.copy(using: &t) ?? glyphs).normalized()
        let bezier = UIBezierPath(cgPath: path)
        bezier.flatness = 0.002
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.materials = [material]
        let holder = SCNNode()
        holder.addChildNode(SCNNode(geometry: shape))
        return holder
    }

    // MARK: Environment

    /// Equirectangular "photo studio": near-black room, soft vertical light
    /// strips around the horizon and a dim ceiling, so turning metal catches
    /// moving highlights.
    static let studioEnvironment: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let bg = CGGradient(colorsSpace: space, colors: [UIColor(white: 0.95, alpha: 1).cgColor,
                                                              UIColor(white: 0.55, alpha: 1).cgColor,
                                                              UIColor(white: 0.30, alpha: 1).cgColor,
                                                              UIColor(white: 0.10, alpha: 1).cgColor] as CFArray,
                                locations: [0, 0.35, 0.55, 1])!
            c.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            func softbox(x: CGFloat, width: CGFloat, top: CGFloat, bottom: CGFloat, white: CGFloat) {
                let g = CGGradient(colorsSpace: space, colors: [UIColor(white: white, alpha: 0).cgColor,
                                                                 UIColor(white: white, alpha: 1).cgColor,
                                                                 UIColor(white: white, alpha: 0).cgColor] as CFArray,
                                   locations: [0, 0.5, 1])!
                c.saveGState()
                c.clip(to: CGRect(x: x - width / 2, y: top, width: width, height: bottom - top))
                c.drawLinearGradient(g, start: CGPoint(x: x - width / 2, y: 0), end: CGPoint(x: x + width / 2, y: 0), options: [])
                c.restoreGState()
            }
            softbox(x: 512, width: 120, top: 120, bottom: 330, white: 1)
            softbox(x: 300, width: 60, top: 150, bottom: 300, white: 0.8)
            softbox(x: 760, width: 90, top: 140, bottom: 320, white: 0.9)
            softbox(x: 40, width: 50, top: 170, bottom: 290, white: 0.5)
            // A long horizontal strip for the face's top-edge glint.
            let strip = CGGradient(colorsSpace: space, colors: [UIColor(white: 1, alpha: 0).cgColor,
                                                                 UIColor(white: 0.9, alpha: 1).cgColor,
                                                                 UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                   locations: [0, 0.5, 1])!
            c.drawLinearGradient(strip, start: CGPoint(x: 0, y: 70), end: CGPoint(x: 0, y: 110), options: [])
        }
    }()
}

private extension UIColor {
    /// This colour scaled towards black, for a faint glow.
    func blended(_ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
    }
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
