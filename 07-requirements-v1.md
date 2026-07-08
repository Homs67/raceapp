# App Requirements — v1.0 (v0.1)

Full requirements for the v1.0 app. Where this conflicts with 05-design-brief.md (written earlier), **this document wins** — notably: session playback is cut from v1.0, and vehicle health is a tab, not a swipe-away page.

**Product statement:** plug in a $35 OBD2 dongle, mount your phone, press one button — see everything your car and phone know, live, and get every sample saved for later.

---

## 1. App structure — 4 tabs

| Tab | Purpose |
|---|---|
| **Record** | Live driving dashboard + Start/Stop session (the home tab) |
| **Health** | Live vehicle-health gauges (slow OBD channels) |
| **Sessions** | Past sessions: list → detail → export |
| **Connection** | OBD2 setup instructions, connection status, settings |

## 2. Recording (R1)

- **R1.1** `[Start Session]` — one button on the Record tab. No setup, no modes, no questions.
- **R1.2** A session captures **every channel the app can see**: all OBD2 channels (fast + slow loops per 03 §8) **and** all phone sensors (GPS incl. per-fix accuracy, accelerometer, gyroscope, barometer) with native timestamps. Not just what's on screen.
- **R1.3** `[Stop Session]` stops and saves. Saving is instant (data was never buffered-only — see R1.5).
- **R1.4** **Recording works without OBD** — phone-only sessions are valid; the UI states what's missing ("No OBD — engine channels not recorded").
- **R1.5** **Never lose a session:** samples are appended to disk as they arrive. A crash, force-quit, phone call, or dead battery loses at most the last few seconds. On next launch, an interrupted session appears in Sessions, marked "recovered."
- **R1.6** **Forgotten-stop handling (simple version):** if the OBD link drops *and* GPS shows stationary for 5 minutes while recording, auto-stop and save, and post a local notification ("Session saved — 42 min"). No prompt mid-drive, no config.
- **R1.7** **Background recording:** continues with screen locked, app backgrounded, or during phone calls (`bluetooth-central` + `location` background modes).
- **R1.8** OBD dropouts mid-session: auto-reconnect silently (backoff 0.5s→5s), mark the gap in the data, never alert while driving.

## 3. Record tab — live dashboard (R2)

- **R2.1** Primary display (always visible while recording or connected): **engine RPM** (dominant element, 7,500 redline zone marked), **vehicle speed**, **throttle position** as a 0–100% bar, **current gear** (large single digit, derived), **G-meter** (friction circle, lat × long, peak-hold), **altitude**.
- **R2.2** Secondary display (from 05 display-requirements paragraph): yaw rate, GPS accuracy ±m, heading, relative elevation, phone battery % and thermal warning.
- **R2.3** Persistent status strip: adapter link / car link (two-stage), live OBD Hz, GPS quality, recording state + elapsed time.
- **R2.4** **Both orientations supported.** Landscape is the designed-for layout (mounted phone: RPM hero center, G-meter beside); portrait stacks vertically. No layout configuration by the user — one opinionated arrangement each.
- **R2.5** Every gauge has a visible **stale/no-data state** distinct from a zero reading.
- **R2.6** Glanceable at speed: dark, high-contrast, huge numerals; zero interaction required while driving.
- **R2.7** Optional **keep-screen-awake** toggle (in Settings) for dashboard-mounted use.

## 4. Health tab (R3)

- **R3.1** Live gauges for all important current vehicle values: coolant temp, oil temp (if supported), intake air temp, ambient temp, fuel level, battery voltage, engine load, barometric pressure, timing advance.
- **R3.2** Header: car identity (VIN-decoded make/model) + check-engine/DTC status, read-only ("1 stored code" — no clearing in v1).
- **R3.3** Same stale/no-data rules as the dashboard (R2.5). Slow-loop values show their age when older than ~10s.
- **R3.4** Values update live whenever connected — no recording required.

## 5. Sessions tab (R4)

- **R4.1** Reverse-chronological list: date/time, duration, distance, and auto-location name (reverse-geocoded start point).
- **R4.2** Session detail — highlights: duration, distance, max/avg speed, max RPM, peak lateral G, peak longitudinal G, elevation gain, temp ranges, and per-channel sample counts with gap indicators (honest data quality).
- **R4.3** Session detail — **GPS map trace** (MapKit) of the drive.
- **R4.4** One-line editable note per session.
- **R4.5** `[Export]` — share sheet with: **CSV** (RaceChrono-compatible column layout — opens in Excel, imports into existing tools, and is v2's import format) + **JSON sidecar** (session metadata: car, VIN, adapter, app version, units, channel inventory).
- **R4.6** Swipe-to-delete with confirm; show total storage used by sessions in Settings.

## 6. Connection tab (R5)

- **R5.1** Connection status (the same state stream as the status strip, with detail) + connect/forget-adapter controls.
- **R5.2** **Simple setup instructions** built in: the 5-step first-time flow from 06-connection-flow.md §2, including the "don't pair in Bluetooth Settings" warning and the not-found recovery checklist (06 §4).
- **R5.3** Settings: units (one global **metric/imperial** toggle, temps follow, default imperial), keep-screen-awake toggle, storage usage.
- **R5.4** **Demo mode:** a "Try with demo data" button that runs the replay transport with a bundled real session — for users without the adapter yet, and for App Store review.
- **R5.5** Privacy statement, visible: everything stays on the phone; no account, no cloud, no data leaves the device except your own exports.

## 7. Cross-cutting requirements (R6)

- **R6.1** Auto-reconnect on every launch: stored adapter connects by itself; "Waiting for ignition…" is a calm state, not an error (06 §3).
- **R6.2** iOS 17+, iPhone only, portrait + landscape. No iPad-optimized layout in v1.
- **R6.3** Thermal/battery self-protection: visible warning when the phone approaches thermal throttling; recording itself never stops for thermal reasons without saving.
- **R6.4** All OBD interaction is read-only. No DTC clearing, no actuation.

## 8. Non-goals (v1.0)

Lap timing or any track awareness · session playback UI (cut — Export covers it) · coaching/analysis (v2, per 01–02) · video · cloud/accounts · Android · CarPlay/Watch · auto-start recording · user-configurable dashboard layouts · per-gauge units.

## 9. Acceptance criteria

1. Driveway spike numbers hold on the real ND2: fast loop ≥5Hz sustained, supported PIDs identified, all rendered.
2. Founder daily-drives for a week + one track day: zero lost/corrupted sessions; auto-reconnect never needs a manual touch; auto-stop catches a forgotten stop.
3. A phone-only session (no OBD) records, lists, and exports cleanly.
4. Exported CSV opens in Excel and imports into RaceChrono without manual fixing.
5. Kill the app mid-recording → relaunch → session appears as "recovered" with data up to seconds before the kill.
6. Demo mode runs the full dashboard with no hardware.
