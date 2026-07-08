# Handoff: Live Data v1.0 — iOS OBD2 Track App

## Overview
Live Data is an iOS app for HPDE / autocross / canyon drivers (reference car: Mazda MX-5 ND2). Plug in a $35 OBD2 BLE dongle, mount the phone, press one button — see everything the car and phone know, live, with every sample recorded for later export. v1.0 is capture-only: no lap timing, no playback UI, no analysis/coaching (those are v2).

Authoritative requirements: **App Requirements v1.0 (v0.1)** (provided by the product owner). This design implements that document: 4 tabs, both orientations, session detail + export (playback cut).

## About the Design Files
The file in this bundle (`Live Data App.dc.html`) is a **design reference created in HTML** — an interactive prototype showing intended look and behavior, not production code. The task is to **recreate these designs natively in Xcode (SwiftUI, iOS 17+)** using standard platform patterns: TabView, CoreBluetooth (`bluetooth-central` background mode), CoreLocation (`location` background mode), CoreMotion, MapKit, share sheet (`UIActivityViewController`). The HTML's simulated telemetry loop is demo scaffolding only — replace with the real OBD2/sensor pipeline.

## Fidelity
**High-fidelity.** Colors, typography, spacing, and copy are final intent. Recreate pixel-perfectly, substituting native equivalents where noted (fonts, map, share sheet).

## App structure — 4 tabs
Tab bar (hidden while recording in the Record tab): **Record** (home) · **Health** · **Sessions** · **Connection**. Icons: record dot (turns red `#FF453A` while recording), pulse line, list lines, signal arcs. Active tint `#F2F5F7`, inactive `rgba(255,255,255,.35)`, bar background `rgba(16,17,21,.94)` with blur + top hairline `rgba(255,255,255,.08)`.

## Screens

### 1. Record tab — idle (portrait)
- Background `#0B0C0F`.
- Top: centered chip row — ADAPTER (green dot `#32D74B`), CAR (green when connected, `rgba(255,255,255,.3)` dot + "CAR —" when not), "OBD {Hz} Hz", "GPS ±{m} m". Chip: `rgba(255,255,255,.06)` bg, radius 6, font 10px/500, letter-spacing 1, color `rgba(255,255,255,.55)`.
- If no OBD: amber notice card (`rgba(255,214,10,.07)` bg, 1px `rgba(255,214,10,.25)` border, radius 12): "**No OBD** — engine channels won't be recorded. GPS, G-meter, barometer and device health still capture. Set up in Connection."
- Center: 140pt circular START button — 4px ring `rgba(255,69,58,.5)` (full `#FF453A` on press), 112pt solid `#FF453A` inner disc, label "START" 15px/600 white, ls 1.5.
- Below: "START SESSION" (Saira Condensed 20px/600) + "No setup, no modes. Every channel is recorded." (12.5px, `rgba(255,255,255,.45)`).
- Footer: "Keeps recording with the screen locked, in the background, or during a phone call." 11px `rgba(255,255,255,.3)`.

### 2. Record tab — recording (portrait live dashboard)
Pure black `#000`, tab bar hidden, left-aligned stack, zero interaction required:
- Status row: REC chip (red `rgba(255,69,58,.15)` bg, pulsing dot 1.2s, "REC {m:ss}") + OBD Hz + GPS chips.
- Tach bar: 20pt tall, radius 5, track `rgba(255,255,255,.07)`; fill white `#F2F5F7` (turns `#FF453A` within 700 rpm of redline); red zone overlay from (redline−700)/redline: `rgba(255,69,58,.18)` + 2px left border `rgba(255,69,58,.7)`. Redline 7,500.
- RPM: 124pt Saira Condensed 600, line-height 0.85, tabular numerals, ls −1; color follows tach fill. Label "RPM" 10px/500 ls 2 `rgba(255,255,255,.4)`.
- Row (gap 52): GEAR — single digit 84pt/700 `#64D2FF`; SPEED — 84pt/600 `#F2F5F7` + unit "MPH"/"KM/H" 15px `rgba(255,255,255,.45)`.
- Throttle: "THR" label 9px + 9pt bar (track `rgba(255,255,255,.08)`, fill `#32D74B`) + "{pct}%" 14px `#32D74B`.
- G-meter (fills remaining space): 188pt friction circle — rings at 0.5g/1.0g `rgba(255,255,255,.09/.15)`, crosshair `.07`; cyan `#64D2FF` dot (7pt r) at (latG, −longG) × 63pt/g clamped to 84pt; 40-point trail polyline `rgba(100,210,255,.4)` 2px; peak-hold ring 4pt `#FFD60A`. Readout beside: "{combined} g" 30px + "PEAK {peak} g" 10px `#FFD60A`. Peaks reset per sim lap (native: per session).
- STOP: full-width 54pt button, `rgba(255,69,58,.16)` bg, `#FF453A` text "STOP · {m:ss}" 15px/600 ls 1.5, radius 14.
- Stale/no-data rule (R2.5): any gauge without fresh data renders "—" at `rgba(255,255,255,.3)` — never a fake zero.

### 3. Record tab — recording (landscape, the designed-for layout)
874×402 reference. Full-bleed black. Layout:
- Top: full-width segmented tach bar (30pt, 15 segments via 2px separators) + label row "RPM ×1000" / "REDLINE 7.5k" (red at `rgba(255,69,58,.8)`).
- Main row: RPM 168pt (left, min-width 340), GEAR 128pt `#64D2FF`, spacer, right column: SPEED 104pt + unit, THR bar (220pt wide) below.
- Bottom strip: 96pt mini friction circle (dot only, 32pt/g scale) + "{g} g / PEAK" readout · hairline divider · ALT / YAW / HDG stats (label 9px, value 20px Saira Condensed) · spacer · chips: ADAPTER, CAR {Hz} Hz (two-stage link), GPS ±m, REC (only while recording).

### 4. Health tab (portrait)
- Header: "MAZDA MX-5" (Saira Condensed 24px) + "ND2 · VIN JM1NDAM75K0313248" (10.5px `rgba(255,255,255,.38)`); right: DTC badge "MIL OFF · 1 CODE" — amber bordered chip, read-only (R3.2, no clearing).
- 2×6 grid of channel cards: `rgba(255,255,255,.045)` bg, 1px `rgba(255,255,255,.08)` border, radius 11, padding 9×12. Each: label (9px ls 1.2 caps) + age/sub right-aligned 9px, value 25px Saira Condensed tabular + unit 11px, 3pt bottom bar (fill = value color).
- Channels: Coolant (green when in safe zone), Oil temp ("—", "not reported by ECU" — the no-data pattern), Intake air, Ambient (shows ">10s stale" age in `#FFD60A`), Fuel level (% — amber below 20), Battery V, Engine load %, Baro (29.91 inHg / 1013 hPa), Timing adv °BTDC, Rel. elevation (`#64D2FF`), Phone battery %, Thermal state.
- Values update live whenever connected; recording not required (R3.4).

### 5. Sessions tab — list (portrait)
- Header "SESSIONS" + total storage "29.9 MB on device".
- Reverse-chron cards: location name (reverse-geocoded start point, 14px/600) + optional badges — "RECOVERED" (amber tint chip, for crash-interrupted sessions, R1.5) and "NO OBD" (gray chip, phone-only sessions, R1.4); date/time 11px; right column duration (16px Saira Condensed) + distance (10.5px).
- Swipe-to-delete with confirm (prototype uses an explicit Delete button + confirm dialog in detail view).

### 6. Sessions tab — detail (portrait)
- Back link + title row (location, recovered badge, date · size).
- **GPS map trace** card: MapKit trace of the drive (prototype shows a stylized dark polyline `#64D2FF` 2.5px, green start dot, red end square).
- Highlights grid (3-col): Duration, Distance, Max/Avg speed, Max RPM, Peak lat G (`#FFD60A`), Peak long G (`#FFD60A`), Elev gain (`#64D2FF`), Coolant range. Tile: label 8.5px caps, value 18px Saira Condensed.
- One-line editable note field ("Add a note — tires, pressures, conditions…").
- Channels card: per-channel sample counts with honest gap indicators — e.g. "RPM · OBD fast — 32,410 — 2 gaps · 4.1 s" (amber) vs "clean" (green). (R4.2)
- Primary button "Export — CSV + JSON" → native share sheet with two items: CSV (RaceChrono-compatible, 41 columns) + JSON sidecar (car, VIN, adapter, app version, units, channel inventory). (R4.5)
- "Delete session…" red text button → destructive confirm alert.

### 7. Connection tab (portrait)
- Connected state: green-tinted card — "VEEPEAK OBDCheck BLE+ · {Hz} Hz", "MAZDA MX-5 (ND2) · 14 PIDs · auto-reconnects every drive. Parked with ignition off? 'Waiting for ignition' is normal, not an error." + "Forget adapter" red text button. Not connected: "Scan for adapters" primary button → scanning list (device name + RSSI) → connecting spinner.
- FIRST-TIME SETUP card: 5 numbered steps (plug into OBD2 port in driver footwell → ignition on → Scan → pick VEEPEAK → done, auto-reconnects).
- Amber warning: "**Don't pair in Bluetooth Settings.** The adapter accepts one connection at a time — pairing there blocks the app from finding it."
- NOT FINDING IT? recovery checklist (LED on / ignition / other OBD app force-quit / replug + wait 10 s).
- SETTINGS group: Units segmented control (Imperial/Metric — one global toggle, temps follow, default imperial), Keep screen awake toggle, Sessions storage row.
- "Try with demo data" outline button (replay transport with bundled session — for users without adapters and App Store review, R5.4).
- Privacy statement: "everything stays on your phone. No account, no cloud — nothing leaves the device except the files you export yourself."

## Interactions & Behavior
- Start/Stop: single tap, no confirmation. On stop, session saves instantly and appears at top of Sessions.
- While recording in Record tab: tab bar hides; other tabs remain reachable after stopping. REC state also appears as a chip on the landscape dashboard.
- Units toggle re-renders every value app-wide immediately.
- Recording robustness (implement natively, not visible UI): append-to-disk as samples arrive; interrupted sessions surface as "recovered" (R1.5); auto-stop after OBD drop + 5 min stationary with local notification (R1.6); silent OBD auto-reconnect 0.5s→5s backoff, gaps marked in data (R1.8); background modes for screen-lock/calls (R1.7).
- Gauge transitions: bar fills animate `width 60–80ms linear`; REC dot pulses (opacity 1→0.25, 1.2s loop); no other animation on the dashboard.
- Stale/no-data: distinct "—" + muted color per gauge; slow-loop values show age when >10 s old.

## State Management
- `connectionState`: idle → scanning → connecting → connected (+ waitingForIgnition); drives two-stage ADAPTER/CAR chips everywhere.
- `recording: Bool`, `recStart: Date`, elapsed timer, per-channel sample counters.
- `units: imperial | metric` (global, persisted), `keepAwake: Bool` (persisted).
- `sessions: [Session]` — id, locationName, date, duration, distance, sizeBytes, recovered, phoneOnly, note, highlights (maxSpd, avgSpd, maxRpm, peakLatG, peakLongG, elevGain, tempRange), channel inventory with gap records.
- Live telemetry stream: rpm, speed, throttle, derived gear (speed/RPM vs ND2 ratio table [5.087, 2.991, 2.035, 1.594, 1.286, 1.000], final drive 2.866), latG/longG (+ peak hold), GPS accuracy, OBD Hz, altitude, yaw, heading, health channels.

## Design Tokens
- **Colors:** background `#000` (dashboards) / `#0B0C0F` (screens); text primary `#F2F5F7`; muted `rgba(255,255,255,.55/.4/.35/.3)`; accent cyan `#64D2FF` (gear, links, primary buttons); green `#32D74B` (throttle, healthy/link-ok); red `#FF453A` (record, redline, brake, destructive); amber `#FFD60A` (peaks, warnings, stale, DTC); card bg `rgba(255,255,255,.045)` + border `rgba(255,255,255,.08)`; sheet bg `#1A1C21`.
- **Type:** Numerals — *Saira Condensed* 500–700, tabular figures, line-height 0.85 for giant sizes (native option: SF Compact Condensed / SF Pro Expanded with monospaced digits). UI text — SF Pro (system). Micro-labels: 9–11px, 500, letter-spacing 1–2, uppercase.
- **Numeral scale:** 168 (landscape RPM) / 124–128 / 84–104 / 25–30 / 16–20.
- **Spacing:** screen padding 22–24pt; card padding 9–16pt; grid gaps 6–10pt.
- **Radius:** chips 6–8, cards/inputs 10–14, buttons 12–14, sheet 24, record button circular.
- **Hit targets:** ≥44pt everywhere; record/stop buttons 54–140pt.

## Assets
No image assets. All icons are simple strokes (tab bar SVGs in the prototype — replace with SF Symbols: `record.circle`, `waveform.path.ecg`, `list.bullet`, `antenna.radiowaves.left.and.right`). Map trace is MapKit at runtime. Fonts: Saira Condensed (Google Fonts, OFL) — or substitute a native condensed SF variant.

## Files
- `Live Data App.dc.html` — interactive prototype, both orientations, all four tabs. Open in a browser; simulated ND2 telemetry runs automatically. Tweakable props (units / redline / G-trail) are prototype-only conveniences.
