# Design Brief — v1 "Live Data" (v0.2)

One page. Scope cut from the earlier draft: **v1 displays and records every channel the OBD2 adapter and the phone can provide. No analysis, no coaching.** The debrief/coaching product (01–02) becomes v2 — v1 is its capture layer, shipped as a useful app on its own.

---

## Product in one sentence

Plug in a $35 OBD2 dongle, mount your phone, and see **everything your car and phone know, live** — big glanceable gauges while driving, and every sample recorded for later.

## User

Same driver as before (beginner→intermediate HPDE/autocross/canyon, MX-5 ND2 launch car), but v1 asks nothing of them: no track selection, no modes, no interpretation. It replaces "Car Scanner + a G-meter app" with one screen built for driving.

## Core flow (4 screens)

1. **Connect:** scan → pick `VEEPEAK` → auto-reconnect forever after. Status chips for OBD link, GPS accuracy, sensor health. The one guided failure path: "adapter already connected to another app." No OBD? Everything phone-side still works — say what's missing.
2. **Live dashboard (the product):** dark, high-contrast, huge numerals, readable at arm's length in sunlight. Zero interaction while driving.
3. **Health page:** the slow channels, one swipe away.
4. **Sessions:** start/stop recording, list of past sessions, per-channel playback (scrub a timeline, gauges replay), CSV export.

## What v1 displays

**OBD2 fast loop (5–15Hz, from 03 §8):**
- RPM (big, center), vehicle speed, throttle % (accelerator pedal % if the ND2 supports it)

**OBD2 slow loop (~0.2Hz, health page):**
- Coolant temp, oil temp (if supported), intake air temp, ambient temp, fuel level, battery voltage, engine load, barometric pressure, timing advance

**OBD2 one-shot:** VIN, DTC/MIL status shown on connect ("1 stored code" — read-only, no clearing)

**Phone sensors (from 04 §1):**
- GPS: speed, heading, altitude, **live accuracy** (±m shown honestly)
- IMU: longitudinal/lateral G as a **friction-circle G-meter** with peak-hold, yaw rate
- Barometer: relative elevation
- Device: battery %, thermal state — warn before a hot-day shutdown

**Small derived extras (cheap, high-delight, all from 04 §3):** current gear (speed/RPM vs. ND2 ratio table), 0-value-risk only — anything requiring fusion or track geometry waits for v2.

## Display requirements (everything that must be visible)

The app must visually present, live: engine RPM as the dominant element with the ND2's 7,500 redline zone marked; vehicle speed; throttle position as a 0–100% bar; the derived current gear as a single large digit; and a friction-circle G-meter plotting lateral versus longitudinal acceleration with a peak-hold trace, alongside a yaw-rate readout. GPS data appears as speed, heading, altitude, and an always-visible accuracy value (±m), with barometric relative elevation beside it. A persistent status strip shows the two-stage connection state (adapter link, car link) with the live OBD sample rate in Hz, GPS signal quality, recording state with elapsed time, and the phone's battery percentage and thermal warning. One swipe away, the health page displays coolant temperature, oil temperature, intake and ambient air temperature, fuel level, battery voltage, engine load, barometric pressure, and timing advance, plus the car's identity (VIN-decoded make/model) and check-engine/DTC status shown read-only at connect. Every gauge must show a visible "stale/no data" state distinct from a zero reading — a dropout must never be mistakable for a measurement — and in session playback these same gauges re-render recorded data with a scrubbable timeline.

## Recording

Everything on screen is also logged: append-only raw samples, timestamped on receipt, survives crash/backgrounding/calls (screen-off capable via `bluetooth-central` + location background modes). Recording is one big button — no setup, no modes.

## Non-goals (v1)

- No lap timing, corner detection, findings, scores, or drills (v2, per 01–02)
- No calibration ceremony — the G-meter self-levels from the gravity vector; a proper mount-calibration step arrives with v2 analysis
- No video, no cloud/accounts, no Android

## Design principles

1. Glanceable or invisible: every element sized for a 0.5s look at speed; anything that needs reading lives on the health page or in playback.
2. Show honesty as a feature: GPS ±m, OBD Hz, and dropout gaps are visible, not hidden.
3. Never lose a session: capture robustness outranks every visual feature.
4. The dashboard should feel like instrumentation, not an app — numbers first, chrome nowhere.

## Success criteria

- Discovery spike numbers hit on real ND2: OBD fast loop ≥5Hz sustained, all supported PIDs identified and rendered.
- Founder daily-drives with it for a week + one Streets of Willow day: zero lost or corrupted sessions, auto-reconnect works without touching the phone.
- A recorded session exports to CSV and opens cleanly in RaceChrono/Excel — proof the v2 analysis layer has real data to build on.

## Open design questions

- Dashboard layout: one fixed opinionated layout (fast to ship, coherent) vs. user-arrangeable tiles (Car Scanner's model)? Leaning fixed for v1.
- Units: metric/imperial toggle only, or per-gauge?
- How prominent should the G-meter be vs. RPM — is v1's hero the engine or the driving?
