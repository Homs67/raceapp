//
//  RaceBoxDeviceScene.swift
//  raceApp
//
//  The case, lit the way the renders on the design board are lit.
//
//  Ported from design/next-features/racebox-3d.html, which is the ground
//  truth for the look. Two structural differences from the prototype:
//  the camera orbits on nested yaw/pitch nodes rather than being positioned
//  and aimed (no degeneracy looking straight down, and a pose change becomes
//  an arc at constant radius), and the model spins under fixed lights rather
//  than the camera orbiting it, so the rim highlights sweep across the case
//  instead of being painted on.
//

import SwiftUI
import SceneKit

enum RaceBoxDevicePose {
    /// Three-quarter view: the device page, connected.
    case angled
    /// Near-top-down: searching. Flat enough to read as a silhouette.
    case top

    var yaw: Float { self == .angled ? -0.60 : -0.08 }
    var pitch: Float { self == .angled ? 0.42 : 1.44 }

    /// Seen from above the case shows its whole footprint, so it needs more
    /// room than the three-quarter view does.
    var fit: Float { self == .angled ? 0.86 : 1.06 }
}

enum RaceBoxDeviceScene {

    static let cameraNodeName = "camera"
    static let spinNodeName = "spin"
    static let orbitYawNodeName = "orbitYaw"
    static let orbitPitchNodeName = "orbitPitch"

    static func make(pose: RaceBoxDevicePose) -> SCNScene? {
        guard let mesh = RaceBoxMesh.shell else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = studioEnvironment
        // The prototype's dark trim: the room is only there to shape the
        // highlights, not to light the case.
        scene.lightingEnvironment.intensity = 0.16

        // model: spin -> recentre -> CAD tilt -> parts
        let spin = SCNNode()
        spin.name = spinNodeName
        let model = SCNNode()
        model.position = SCNVector3(-mesh.center.x, -mesh.center.y, -mesh.center.z)
        let tilt = SCNNode()
        tilt.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)   // CAD is Z-up

        let materials = makeMaterials()
        for part in mesh.parts {
            let node = SCNNode(geometry: part.geometry)
            node.name = part.name
            node.geometry?.materials = [materials[part.material]!]
            tilt.addChildNode(node)
        }
        model.addChildNode(tilt)
        spin.addChildNode(model)
        scene.rootNode.addChildNode(spin)

        // camera: orbitYaw -> orbitPitch -> camera, all through the origin
        let camera = SCNCamera()
        camera.fieldOfView = 26
        camera.projectionDirection = .vertical
        camera.zNear = 100
        camera.zFar = 500
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0
        camera.colorFringeStrength = 0
        camera.vignettingIntensity = 0

        let cameraNode = SCNNode()
        cameraNode.name = cameraNodeName
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, cameraDistance(for: pose))

        let orbitPitch = SCNNode()
        orbitPitch.name = orbitPitchNodeName
        orbitPitch.eulerAngles = SCNVector3(-pose.pitch, 0, 0)
        orbitPitch.addChildNode(cameraNode)

        let orbitYaw = SCNNode()
        orbitYaw.name = orbitYawNodeName
        orbitYaw.eulerAngles = SCNVector3(0, pose.yaw, 0)
        orbitYaw.addChildNode(orbitPitch)
        scene.rootNode.addChildNode(orbitYaw)

        for light in makeLights() { scene.rootNode.addChildNode(light) }
        return scene
    }

    /// Framing from the bounding sphere, the way the prototype does it.
    ///
    /// The case is a flat box, so its bounding sphere is much taller than the
    /// device ever is on screen; framing the sphere at the prototype's 1.05
    /// leaves the hero half empty. Each pose carries its own fit instead.
    static func cameraDistance(for pose: RaceBoxDevicePose, aspect: Float = 1) -> Float {
        let radius = RaceBoxMesh.shell?.radius ?? 58.2
        let vfov = 26 * Float.pi / 180
        let hfov = 2 * atan(tan(vfov / 2) * aspect)
        return radius * pose.fit / sin(min(vfov, hfov) / 2)
    }

    // MARK: - Look

    private static func makeMaterials() -> [RaceBoxMesh.MaterialKey: SCNMaterial] {
        func pbr(_ hex: UInt32, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(Color(hex: hex))
            m.roughness.contents = roughness
            m.metalness.contents = metalness
            return m
        }
        let plastic = pbr(0x060607, roughness: 0.78, metalness: 0)
        let red = pbr(0xE0150C, roughness: 0.30, metalness: 0)
        red.emission.contents = UIColor(Color(hex: 0x500000))
        let steel = pbr(0xB4B7BC, roughness: 0.28, metalness: 1)
        return [.plastic: plastic, .red: red, .steel: steel]
    }

    /// The prototype's three directional lights, at its dark-trim intensities.
    /// Its hemisphere light has no SceneKit equivalent and is not needed — the
    /// environment already encodes a bright ceiling over a dark floor.
    private static func makeLights() -> [SCNNode] {
        func directional(_ hex: UInt32, _ lumens: CGFloat, _ position: SCNVector3) -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.color = UIColor(Color(hex: hex))
            light.intensity = lumens
            light.castsShadow = false
            let node = SCNNode()
            node.light = light
            node.position = position
            node.look(at: SCNVector3Zero)
            return node
        }
        // The prototype's warm rim is its brightest light. Carried over at
        // that ratio, SceneKit renders the case tan rather than graphite:
        // three.js tonemaps through ACES, which desaturates a hot highlight,
        // and SceneKit does not. So the rim is pulled back and most of its
        // warmth taken out — the sheen stays, the colour cast goes.
        return [
            directional(0xFFFFFF, 620, SCNVector3(-120, 260, 160)),   // key
            directional(0xFFF4EE, 520, SCNVector3(180, 60, -200)),    // rim
            directional(0xFFFFFF, 360, SCNVector3(-200, 40, -120)),   // fill rim
        ]
    }

    /// The prototype builds its environment by rendering a box with four
    /// bright panels. Here the same room is ray-cast straight into an
    /// equirectangular image. Panel values exceed 1, so everything is scaled
    /// down and `lightingEnvironment.intensity` carries the scale back.
    static let studioEnvironment: UIImage = {
        let w = 256, h = 128
        let panels: [(axis: Int, at: Float, u: ClosedRange<Float>, v: ClosedRange<Float>, value: Float)] = [
            (1, 4.9, -3 ... 3, -1.5 ... 1.5, 1.4),      // ceiling
            (0, -4.9, -0.5 ... 2.5, -1 ... 3, 3.0),     // left, brightest
            (0, 4.9, -3 ... -1, -1.5 ... 2.5, 2.2),     // right
            (2, -4.9, -2.5 ... 2.5, 0.75 ... 2.25, 1.6),// back
        ]
        let room: Float = 4.9
        let ambient: Float = 0x2A / 255

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            let theta = Float(y) / Float(h) * .pi
            for x in 0 ..< w {
                let phi = Float(x) / Float(w) * 2 * .pi - .pi
                let d = SIMD3<Float>(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi))

                // Nearest exit through the box, then see which panel it lands on.
                var best = Float.greatestFiniteMagnitude
                var axis = 0
                for a in 0 ..< 3 where abs(d[a]) > 1e-6 {
                    let t = room / abs(d[a])
                    if t < best { best = t; axis = a }
                }
                let hit = d * best
                var value = ambient
                for p in panels where p.axis == axis && (hit[axis] > 0) == (p.at > 0) {
                    let (ui, vi) = p.axis == 0 ? (2, 1) : (p.axis == 1 ? (0, 2) : (0, 1))
                    if p.u.contains(hit[ui]) && p.v.contains(hit[vi]) { value = p.value / 3 }
                }
                let byte = UInt8(max(0, min(255, value * 255)))
                let i = (y * w + x) * 4
                pixels[i] = byte; pixels[i + 1] = byte; pixels[i + 2] = byte; pixels[i + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return UIImage(cgImage: ctx.makeImage()!)
    }()
}
