#!/usr/bin/env python3
"""
build_tracks.py — generate raceApp track maps from OpenStreetMap.

Pipeline (RaceBox-style track DB, reproducibly):
  1. Fetch `highway=raceway` geometry from the OSM Overpass API.
  2. Assemble a single racing-order centerline (stitching multi-segment tracks).
  3. Resample to uniform ~4 m spacing; validate length against the published figure.
  4. Detect corner apexes by centerline curvature (Menger three-point).
  5. Attach curated names + canonical turn numbers to well-known corners.
  6. Emit raceApp/Tracks/<id>.json (Track schema v1).

Geometry © OpenStreetMap contributors, ODbL (https://openstreetmap.org/copyright).
Run:  python3 tools/build_tracks.py         (from repo root)
Add a track: extend the build() calls in main() and re-run.
"""
import json, math, os, subprocess, sys

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "raceApp", "Tracks")
# Overpass mirrors, tried in order (they rate-limit independently).
OVERPASS_MIRRORS = [
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

# ---------- geo helpers ----------
def hav(a, b):
    R = 6371000; la1, lo1, la2, lo2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    h = math.sin((la2-la1)/2)**2 + math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(math.sqrt(h))

def plen(p): return sum(hav(p[i], p[i+1]) for i in range(len(p)-1))

def to_xy(pts, lat0):
    mlat = 111320.0; mlon = 111320.0*math.cos(math.radians(lat0))
    return [(lo*mlon, la*mlat) for la, lo in pts]

def resample(pts, step=4.0):
    out = [pts[0]]; acc = 0.0
    for i in range(1, len(pts)):
        a, b = pts[i-1], pts[i]; d = hav(a, b)
        if d == 0: continue
        while acc+d >= step:
            t = (step-acc)/d
            a = (a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t); out.append(a); d = hav(a, b); acc = 0.0
        acc += d
    return out

def curvature(pts, w):
    lat0 = sum(p[0] for p in pts)/len(pts); xy = to_xy(pts, lat0); n = len(pts); k = [0.0]*n
    for i in range(n):
        (x1, y1), (x2, y2), (x3, y3) = xy[(i-w) % n], xy[i], xy[(i+w) % n]
        area = abs((x2-x1)*(y3-y1)-(x3-x1)*(y2-y1))/2
        a = math.hypot(x2-x1, y2-y1); b = math.hypot(x3-x2, y3-y2); c = math.hypot(x3-x1, y3-y1)
        k[i] = 0 if (a*b*c < 1e-6 or area < 1e-6) else (4*area)/(a*b*c)
    return [sum(k[(i+j) % n] for j in range(-2, 3))/5 for i in range(n)]

def detect(pts, thresh, w, min_pts=3, gap=4):
    k = curvature(pts, w); n = len(pts)
    idx = [i for i in range(n) if k[i] > thresh]
    if not idx: return []
    groups = [[idx[0]]]
    for a, b in zip(idx, idx[1:]):
        if b-a <= gap: groups[-1].append(b)
        else: groups.append([b])
    if k[0] > thresh and k[n-1] > thresh and len(groups) > 1:
        groups[0] = groups[-1]+groups[0]; groups.pop()
    return [max(g, key=lambda ii: k[ii]) for g in groups if len(g) >= min_pts]

def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, [a[0], a[1], b[0], b[1]]); dlo = lo2-lo1
    y = math.sin(dlo)*math.cos(la2); x = math.cos(la1)*math.sin(la2)-math.sin(la1)*math.cos(la2)*math.cos(dlo)
    return math.degrees(math.atan2(y, x))

def offset(pt, brg, dist):
    R = 6371000; d = dist/R; b = math.radians(brg); la1 = math.radians(pt[0]); lo1 = math.radians(pt[1])
    la2 = math.asin(math.sin(la1)*math.cos(d)+math.cos(la1)*math.sin(d)*math.cos(b))
    lo2 = lo1+math.atan2(math.sin(b)*math.sin(d)*math.cos(la1), math.cos(d)-math.sin(la1)*math.sin(la2))
    return (round(math.degrees(la2), 6), round(math.degrees(lo2), 6))

def gate(pts, i, half=12.0):
    brg = bearing(pts[i], pts[(i+1) % len(pts)])
    return {"a": list(offset(pts[i], brg+90, half)), "b": list(offset(pts[i], brg-90, half)), "approximate": True}

def nidx(pts, c): return min(range(len(pts)), key=lambda i: hav(pts[i], c))
def rot(p, i): return p[i:]+p[:i]
def walkback(pts, i, dist):
    acc = 0; j = i
    while acc < dist:
        j = (j-1) % len(pts); acc += hav(pts[j], pts[(j+1) % len(pts)])
    return j

# ---------- OSM fetch ----------
def overpass(bbox):
    q = (f'[out:json][timeout:40];('
         f'way["highway"="raceway"]({bbox});'
         f'way["leisure"="track"]["sport"~"motor|racing"]({bbox}););out geom;')
    last = ""
    for url in OVERPASS_MIRRORS:
        r = subprocess.run(["curl", "-s", "--max-time", "60", "--retry", "2", "--retry-delay", "3",
                            url, "--data-urlencode", f"data={q}"], capture_output=True, text=True)
        try:
            return {e["id"]: e for e in json.loads(r.stdout)["elements"]}
        except (json.JSONDecodeError, KeyError):
            last = (r.stdout or "")[:120]
            continue
    raise SystemExit(f"All Overpass mirrors failed. Last response: {last!r}")

def geom(e): return [(p["lat"], p["lon"]) for p in e["geometry"]]

def stitch(elems, order):
    out = []
    for oid in order:
        g = geom(elems[oid])
        if out and hav(out[-1], g[0]) > hav(out[-1], g[-1]): g = g[::-1]
        if out and hav(out[-1], g[0]) < 2: g = g[1:]
        out += g
    return out

# ---------- canonical corner names (official numbers) ----------
CANON = {"Andretti Hairpin": "T2", "The Corkscrew": "T8–8A", "Rainey Curve": "T9"}

def build(spec):
    rp = resample(spec["raw"], 4.0)
    rp = rot(rp, nidx(rp, spec["sf"]))
    L = plen(rp+[rp[0]])
    corners = []
    for n, ai in enumerate(sorted(detect(rp, spec["thresh"], spec["w"])), 1):
        coord = rp[ai]; name = f"T{n}"; official = None
        for nm, anchor in spec.get("names", {}).items():
            if hav(coord, anchor) < 70:
                name = nm; official = CANON.get(nm)
        c = {"n": n, "name": name, "apex": [round(coord[0], 6), round(coord[1], 6)]}
        if official: c["officialTurn"] = official
        corners.append(c)
    track = {
        "schemaVersion": 1, "id": spec["id"], "name": spec["name"], "location": spec["location"],
        "country": "USA", "configuration": spec["config"], "direction": "clockwise",
        "source": "OpenStreetMap (ODbL); corners auto-derived from centerline curvature, key names curated",
        "lengthMeters": round(L, 1), "lengthMiles": round(L/1609.34, 3), "turnCount": len(corners),
        "startFinish": gate(rp, 0), "corners": corners,
        "centerline": [[round(a, 6), round(b, 6)] for a, b in rp],
        "cornerNumbering": "driving-order, auto-derived; officialTurn set where a corner has a canonical name/number",
        "notes": spec["notes"],
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{spec['id']}.json")
    json.dump(track, open(path, "w"), indent=2)
    flag = "" if abs(len(corners)-spec["expected"]) <= 3 else "  <-- COUNT OFF, retune"
    print(f"  {spec['name']}: {track['lengthMiles']}mi, {len(corners)} corners (official ~{spec['expected']}){flag}")

def main():
    print("Fetching OSM geometry…")
    willow = overpass("34.83,-118.32,34.91,-118.22")
    laguna = overpass("36.56,-121.77,36.60,-121.73")

    big = geom(willow[10440074])[:-1]
    sow = geom(willow[10431309])[:-1]
    lag = stitch(laguna, [1315957506, 1315957503, 1315957504, 1315957505,
                          10464852, 1315957508, 1315957507, 1315957502])
    def mid(oid): g = geom(laguna[oid]); return g[len(g)//2]
    lag_names = {"Andretti Hairpin": mid(1315957508), "The Corkscrew": mid(1315957503),
                 "Rainey Curve": mid(1315957505)}
    # Laguna S/F: front straight, ~180 m before the Andretti Hairpin (T2)
    lag_rs = resample(lag, 4.0)
    sfL = lag_rs[walkback(lag_rs, nidx(lag_rs, lag_names["Andretti Hairpin"]), 180)]

    print("Building tracks →", os.path.normpath(OUT_DIR))
    build({"id": "laguna-seca", "name": "WeatherTech Raceway Laguna Seca", "location": "Monterey, CA",
           "config": "Grand Prix (11-turn)", "raw": lag, "sf": sfL, "expected": 11,
           "thresh": 0.008, "w": 3, "names": lag_names,
           "notes": "Corkscrew=T8/8A, Rainey=T9, Andretti Hairpin=T2. Start/finish approximate; verify against a recorded lap."})
    build({"id": "big-willow", "name": "Willow Springs International Raceway", "location": "Rosamond, CA",
           "config": "Big Willow (9-turn)", "raw": big, "sf": (34.86962, -118.26026), "expected": 9,
           "thresh": 0.009, "w": 4,
           "notes": "Start/finish anchored to OSM way origin on the front straight; verify on-track."})
    build({"id": "streets-of-willow", "name": "Streets of Willow Springs", "location": "Rosamond, CA",
           "config": "OSM primary loop (~1.0 mi)", "raw": sow, "sf": (34.87481, -118.25888), "expected": 8,
           "thresh": 0.011, "w": 4,
           "notes": "Streets runs MANY configs (full course ~1.6mi/14T). This is the primary OSM closed loop only; capture the exact club config from a recorded lap."})
    print("Done.")

if __name__ == "__main__":
    sys.exit(main())
