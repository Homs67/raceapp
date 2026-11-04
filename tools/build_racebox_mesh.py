#!/usr/bin/env python3
"""Turn the printed-case CAD export into a mesh the app can render.

    design/next-features/racebox-model.js   (three.js prototype data)
        -> raceApp/Models3D/RaceBoxShell.json   manifest
        -> raceApp/Models3D/RaceBoxShell.bin    positions + normals + indices

The source stores Int16 positions on a 0.002 grid, Uint16 indices, and no
normals at all -- the prototype calls computeVertexNormals() at load. We do the
same thing here, once, so the app does no per-vertex work on the main thread.

Two things matter and are easy to get wrong:

* Only the case ships. From straight above you would otherwise see the PCB,
  antenna and battery through the lid's vent holes; that is what the
  prototype's `shell=1` flag exists to fix.
* Never weld vertices by position. The exporter already split the mesh at every
  CAD edge, so averaging over the given topology keeps chamfers and vent rims
  crisp. Welding first turns them into blobs.

Run from the repo root:  python3 tools/build_racebox_mesh.py [--check]
"""

import base64
import hashlib
import json
import math
import re
import struct
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design/next-features/racebox-model.js"
OUT_DIR = ROOT / "raceApp/Models3D"

# Parts that are not the case at all.
DROP = re.compile(r"DASHBOARD_BASE|SLED")
# Internals: invisible with the lid on, and visible *through* it from above.
INTERNAL = re.compile(
    r"^(RaceBox_|battery|bq25185|switch_PCB|switch_JST|physical_switch_body"
    r"|countersunk|screw$)"
)


def material_for(name):
    """The prototype's material cascade, resolved at build time."""
    if "RED_CENTER" in name:
        return "red"
    if name == "screw" or name.startswith("physical_switch_slider"):
        return "steel"
    return "plastic"


def load_source():
    text = SOURCE.read_text()
    payload = text[text.index("{"):].rstrip().rstrip(";")
    model = json.loads(payload)
    return model, hashlib.sha256(text.encode()).hexdigest()


def vertex_normals(positions, indices):
    """three.js computeVertexNormals: accumulate the un-normalised cross
    product of each face into its three vertices, then normalise. The missing
    normalisation is the area weighting -- dropping it changes the result."""
    n = [0.0] * len(positions)
    for i in range(0, len(indices), 3):
        a, b, c = (indices[i] * 3, indices[i + 1] * 3, indices[i + 2] * 3)
        abx = positions[b] - positions[a]
        aby = positions[b + 1] - positions[a + 1]
        abz = positions[b + 2] - positions[a + 2]
        acx = positions[c] - positions[a]
        acy = positions[c + 1] - positions[a + 1]
        acz = positions[c + 2] - positions[a + 2]
        nx = aby * acz - abz * acy
        ny = abz * acx - abx * acz
        nz = abx * acy - aby * acx
        for v in (a, b, c):
            n[v] += nx
            n[v + 1] += ny
            n[v + 2] += nz
    for i in range(0, len(n), 3):
        length = math.sqrt(n[i] * n[i] + n[i + 1] * n[i + 1] + n[i + 2] * n[i + 2])
        if length > 0:
            n[i] /= length
            n[i + 1] /= length
            n[i + 2] /= length
    return n


def build():
    model, digest = load_source()
    q = model["q"]
    blob = base64.b64decode(model["bin"])

    positions, normals, indices, parts = [], [], [], []
    body_points = []

    for part in model["parts"]:
        name = part["name"]
        if DROP.search(name) or INTERNAL.match(name):
            continue
        nv, ni = part["nv"], part["ni"]
        raw_pos = struct.unpack_from("<%dh" % (nv * 3), blob, part["pOff"])
        part_pos = [v * q for v in raw_pos]
        part_idx = list(struct.unpack_from("<%dH" % ni, blob, part["iOff"]))

        parts.append({
            "name": name,
            "material": material_for(name),
            "firstVertex": len(positions) // 3,
            "vertexCount": nv,
            "firstIndex": len(indices),
            "indexCount": ni,
        })
        positions.extend(part_pos)
        normals.extend(vertex_normals(part_pos, part_idx))
        indices.extend(part_idx)

        # The prototype frames on the body halves only, so the shot does not
        # shift if the part set is ever changed.
        if "BODY" in name:
            body_points.append(part_pos)

    # The model node is rotated -90 degrees about X (Z-up CAD to Y-up scene),
    # so frame in that tilted space: (x, z, -y).
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for pts in body_points:
        for i in range(0, len(pts), 3):
            for axis, value in enumerate((pts[i], pts[i + 2], -pts[i + 1])):
                lo[axis] = min(lo[axis], value)
                hi[axis] = max(hi[axis], value)
    center = [(lo[i] + hi[i]) / 2 for i in range(3)]
    radius = math.sqrt(sum(((hi[i] - lo[i]) / 2) ** 2 for i in range(3)))

    def pad(data):
        return data + b"\0" * (-len(data) % 16)

    pos_bytes = pad(struct.pack("<%df" % len(positions), *positions))
    nrm_bytes = pad(struct.pack("<%df" % len(normals), *normals))
    idx_bytes = pad(struct.pack("<%dH" % len(indices), *indices))

    manifest = {
        "format": 1,
        "generator": "tools/build_racebox_mesh.py",
        "source": SOURCE.relative_to(ROOT).as_posix(),
        "sourceSHA256": digest,
        "vertexCount": len(positions) // 3,
        "triangleCount": len(indices) // 3,
        "frame": {"center": center, "radius": radius},
        "positions": {"offset": 0, "length": len(pos_bytes)},
        "normals": {"offset": len(pos_bytes), "length": len(nrm_bytes)},
        "indices": {"offset": len(pos_bytes) + len(nrm_bytes), "length": len(idx_bytes)},
        "parts": parts,
    }
    return manifest, pos_bytes + nrm_bytes + idx_bytes


def main():
    manifest, blob = build()
    check = "--check" in sys.argv
    out = Path(tempfile.mkdtemp()) if check else OUT_DIR
    out.mkdir(parents=True, exist_ok=True)
    (out / "RaceBoxShell.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "RaceBoxShell.bin").write_bytes(blob)

    if check:
        for name in ("RaceBoxShell.json", "RaceBoxShell.bin"):
            if (OUT_DIR / name).read_bytes() != (out / name).read_bytes():
                sys.exit("%s is stale -- rerun tools/build_racebox_mesh.py" % name)
        print("up to date")
        return

    print("%d parts, %d vertices, %d triangles, %d bytes" % (
        len(manifest["parts"]), manifest["vertexCount"],
        manifest["triangleCount"], len(blob)))
    print("frame center %s radius %.3f" % (
        ["%.2f" % v for v in manifest["frame"]["center"]], manifest["frame"]["radius"]))


if __name__ == "__main__":
    main()
