# Track Maps

Bundled track-map database for showing the driven line, timing laps, and segmenting
corners on-track. This is **v2 groundwork** — v1 "Live Data" (per `05-design-brief.md`
non-goals) does not yet do lap timing or corner detection. The data is seeded now so
the lap engine has real tracks to build against.

## Files

| File | Track | Length (computed) | Corners |
|---|---|---|---|
| `laguna-seca.json` | WeatherTech Raceway Laguna Seca | 2.237 mi (official 2.238) | 13 detected (11 official) |
| `big-willow.json` | Willow Springs Int'l (Big Willow) | 2.45 mi (official 2.5) | 9 (9 official) |
| `streets-of-willow.json` | Streets of Willow Springs | 0.99 mi | 8 (OSM short loop) |

Schema: `Track` in `../Model/Track.swift` (v1). Loaded by `TrackDatabase.all`.

## Provenance & confidence

- **Geometry (centerline, length):** high-confidence. Sourced from **OpenStreetMap**
  `highway=raceway` ways and validated against each track's published length (all within
  ~1%). Laguna is stitched from OSM's named segments (Corkscrew, Rainey Curve, Andretti
  Hairpin, Rahal Straight, …) — the stitched loop computes to 3600 m vs. the official
  3602 m, which is how we know the segment order is right.
- **Start/finish gate:** **approximate** (`startFinish.approximate == true`). Best-effort
  placement on the front straight. Must be confirmed against a real recorded lap before
  lap times can be trusted.
- **Corner numbering:** **auto-derived** from centerline curvature, numbered in driving
  order — this is *not* guaranteed to match the circuit's official numbering (some
  official "turns" are gentle kinks below the curvature threshold; some single turns have
  two apexes). Where a corner has a canonical identity we set `officialTurn`
  (e.g. Laguna's Corkscrew → `T8–8A`). Apex *coordinates* are usable for segmentation as-is.
- **Timing accuracy caveat:** at 1 Hz phone GPS a car covers ~30 m between fixes at
  60 mph, so gate-crossing time carries roughly ±0.3–0.5 s even with interpolation. Fine
  for "am I improving," not for splitting hundredths. Precise line/apex work is the Tier 2
  (25 Hz GPS) unlock — see `04-data-capabilities.md §4`.

## Licensing

Track geometry is **© OpenStreetMap contributors, licensed ODbL**
(https://openstreetmap.org/copyright). Attribution must be surfaced in-app (e.g. an
"About / Data sources" screen). ODbL is share-alike for derived *databases* — keep that in
mind before treating a curated track set as proprietary.

## Regenerating / adding tracks

Everything here is reproducible from `../../tools/build_tracks.py`:

```
python3 tools/build_tracks.py        # from repo root — fetches OSM, rebuilds all JSON
```

To add a track: find its OSM raceway way id(s), add a `build({...})` call in `main()`
with a bounding box, start/finish anchor, and per-track curvature threshold, then re-run.
For tracks OSM maps as one closed way (like Big Willow) it's a one-liner; multi-segment
tracks (like Laguna) need a `stitch()` order. Verify the printed length against the
published figure — a large mismatch means the wrong way or a bad stitch.
