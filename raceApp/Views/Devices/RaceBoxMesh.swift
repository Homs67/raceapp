//
//  RaceBoxMesh.swift
//  raceApp
//
//  Loads the printed case, built by tools/build_racebox_mesh.py.
//

import Foundation
import SceneKit

/// The case geometry, decoded once per process.
///
/// `SCNGeometry` is immutable, so the live hero and any still render share
/// these buffers. Positions and normals are handed to SceneKit as offsets into
/// one memory-mapped file — there is no per-vertex work at load.
struct RaceBoxMesh {

    enum MaterialKey: String, Decodable { case plastic, red, steel }

    struct Part {
        let name: String
        let material: MaterialKey
        let geometry: SCNGeometry
    }

    let parts: [Part]
    /// Bounding sphere of the case body, in the scene's Y-up frame.
    let center: SCNVector3
    let radius: Float

    static let shell: RaceBoxMesh? = load(named: "RaceBoxShell")

    // MARK: - Manifest

    private struct Manifest: Decodable {
        struct Range: Decodable { let offset: Int; let length: Int }
        struct Frame: Decodable { let center: [Float]; let radius: Float }
        struct Part: Decodable {
            let name: String
            let material: MaterialKey
            let firstVertex: Int
            let vertexCount: Int
            let firstIndex: Int
            let indexCount: Int
        }
        let frame: Frame
        let positions: Range
        let normals: Range
        let indices: Range
        let parts: [Part]
    }

    private static func load(named name: String) -> RaceBoxMesh? {
        guard let jsonURL = Bundle.main.url(forResource: name, withExtension: "json"),
              let binURL = Bundle.main.url(forResource: name, withExtension: "bin"),
              let manifestData = try? Data(contentsOf: jsonURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              let blob = try? Data(contentsOf: binURL, options: .mappedIfSafe)
        else { return nil }

        let stride = MemoryLayout<Float>.size * 3

        let parts: [Part] = manifest.parts.map { part in
            let positions = SCNGeometrySource(
                data: blob, semantic: .vertex, vectorCount: part.vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: manifest.positions.offset + part.firstVertex * stride,
                dataStride: stride)

            let normals = SCNGeometrySource(
                data: blob, semantic: .normal, vectorCount: part.vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: manifest.normals.offset + part.firstVertex * stride,
                dataStride: stride)

            // SCNGeometryElement has no offset parameter, so this one range is
            // copied out. 254 KB, once.
            let low = manifest.indices.offset + part.firstIndex * 2
            let element = SCNGeometryElement(
                data: blob.subdata(in: low ..< low + part.indexCount * 2),
                primitiveType: .triangles,
                primitiveCount: part.indexCount / 3,
                bytesPerIndex: 2)

            let geometry = SCNGeometry(sources: [positions, normals], elements: [element])
            geometry.name = part.name
            return Part(name: part.name, material: part.material, geometry: geometry)
        }

        let c = manifest.frame.center
        return RaceBoxMesh(parts: parts,
                           center: SCNVector3(c[0], c[1], c[2]),
                           radius: manifest.frame.radius)
    }
}
