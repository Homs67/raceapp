# Driving Coach App — System Architecture (v0.1)

**Project:** AI performance-driving coach for beginner/intermediate amateurs
**Founder context:** 2022 MX-5 Club (ND2, 6MT) · SoCal tracks (Streets of Willow, Big Willow, autocross, time attack) + canyon driving
**Last updated:** 2026-07-04

---

## 1. Product principles (decided in brainstorming)

1. **Coaching-first, hardware-later.** The moat is the translation layer (data → advice), not data capture. Integrate with existing devices first; white-label/OEM hardware (RaceBox Micro module) is Phase 2.
2. **Local-first processing.** Telemetry analysis runs on-device (telemetry is only a few MB/session). Cloud is optional and used only for LLM narrative generation + future community references. Video never leaves the device unless the user opts in. Privacy is a selling point, especially for canyon drivers.
3. **Post-session analysis first.** Real-time audio coaching is Tier 3 / later (latency + safety + liability).
4. **Graceful degradation.** Coaching engine works at every data tier and tells users what better data unlocks (built-in upsell: "±8m GPS uncertainty — a 10Hz GPS would make this braking marker precise").
5. **Less is more.** Max 3 prioritized findings per session, each measurable, each with estimated time gain. One drill per next session. (Grounded in HPDE coaching best practice + Garmin Catalyst criticism research.)
6. **Compare to BEST lap, not average.** (Catalyst's most-criticized flaw.)
7. **Liability posture:** marketed as closed-course motorsport education. Canyon mode coaches *technique quality*, never "go faster on public roads." Disclaimer on every report.

## 2. Product tiers

| Tier | Hardware | Unlocks |
|---|---|---|
| **1 (MVP)** | iPhone (GPS 1Hz + IMU 100Hz) + OBD2 BLE adapter + optional GoPro/dashcam video | Full post-session coaching: coasting, braking G/consistency, rev-match, shift points, throttle, smoothness, fatigue trends. Video as delivery medium with telemetry overlay. |
| **2** | + 10/25Hz GPS (RaceBox Mini S via BLE, or imports) | Precise braking markers, racing line vs track edges, apex position, sector deltas, line coaching |
| **3 (later)** | Same as 2 | Real-time audio coaching in-ear |

**Dev hardware:** Veepeak OBDCheck BLE+ (baseline — design for slowest common adapter), OBDLink MX+ (fast reference), RaceBox Mini S (Tier 2 target; documented BLE protocol, 25Hz, built-in storage).

## 3. High-level system diagram

```
┌─────────────────────────────────────────────────────────┐
│                     iOS APP (Swift/SwiftUI)              │
│                                                          │
│  INGESTION           PROCESSING            PRESENTATION  │
│  ┌──────────┐       ┌─────────────┐       ┌───────────┐ │
│  │ Live:    │       │ Sensor      │       │ Session   │ │
│  │ CoreLoc  │──┐    │ fusion      │       │ debrief   │ │
│  │ CoreMotn │  │    │ (GPS+IMU)   │       │ report    │ │
│  │ OBD2 BLE │  ├──▶ │      ↓      │ ────▶ │           │ │
│  │ RaceBox  │  │    │ Lap/corner  │       │ Video     │ │
│  │ BLE      │  │    │ segmentation│       │ player w/ │ │
│  ├──────────┤  │    │      ↓      │       │ overlay + │ │
│  │ Import:  │  │    │ Detector    │       │ deep links│ │
│  │ GoPro MP4│──┘    │ suite       │       │           │ │
│  │ RaceChrono│      │      ↓      │       │ Progress  │ │
│  │ CSV/VBO  │       │ Prioritizer │       │ trends    │ │
│  └──────────┘       └─────────────┘       └───────────┘ │
│         │                   │                            │
│  ┌──────▼───────────────────▼──────────┐                │
│  │ LOCAL STORE (SQLite/GRDB)           │                │
│  │ sessions, channels, laps, corners,  │                │
│  │ findings, tracks, video refs        │                │
│  └──────────────┬──────────────────────┘                │
└─────────────────┼────────────────────────────────────────┘
                  │ opt-in, telemetry summary only (KBs)
          ┌───────▼────────┐
          │ CLOUD (Phase 1b)│
          │ LLM narrative   │
          │ generation;     │
          │ later: community│
          │ reference laps  │
          └────────────────┘
```

## 4. Ingestion layer

### 4.1 Live capture (during session)
- **CoreLocation:** GPS @ ~1Hz, `kCLLocationAccuracyBestForNavigation`. Record raw fixes + horizontal accuracy per fix (feeds confidence scoring).
- **CoreMotion:** accel + gyro @ 100Hz. Device orientation calibration step at session start (car level, phone mounted). Store raw; gravity-compensate in processing.
- **OBD2 via CoreBluetooth:** ELM327-over-BLE protocol. Poll a minimal PID set for max rate: RPM (0x0C), speed (0x0D), throttle (0x11). Optional slow loop (every ~5s): coolant temp (0x05), intake temp. Expect 5–10 Hz total on Veepeak-class adapters. **Gear is derived**, not read: gear = f(speed/RPM ratio) matched against ND2 gear ratios (ship with a per-car ratio table; MX-5 ND2 6MT first).
- **RaceBox Mini S via CoreBluetooth (Tier 2):** 25Hz GPS + built-in IMU. Public protocol docs exist. Also support post-session download from its onboard storage.
- Recording must survive backgrounding, phone calls, thermal throttling. Write append-only to disk as we go (crash = lose seconds, not the session).

### 4.2 File import (post-session)
- **Video:** MP4/MOV from GoPro, dashcam SD, or iPhone camera via Files/Photos. Parse GoPro GPMF metadata track when present (GoPros embed GPS + accel!) — free bonus telemetry.
- **Telemetry files:** RaceChrono CSV, VBO (VBOX), NMEA logs, RaceBox session exports. Import = instant onboarding for users with existing session libraries. Normalize everything into the internal channel model.

### 4.3 Time alignment (critical design decision)
- **Master timeline** = GPS time (UTC). Every channel keeps its own native timestamps and sample rate; nothing is resampled at ingest.
- Channels are irregular by nature (OBD especially). All processing reads channels through an **interpolation accessor** (`value(at: t)`), never assumes uniform rate.
- **Video sync strategies, in priority order:**
  1. GoPro GPMF GPS timestamps (when present)
  2. **Audio-RPM cross-correlation:** FFT the video's audio track → engine RPM estimate curve; cross-correlate against OBD RPM channel → sub-second sync offset. (Also serves as OBD dropout backup.) Use Accelerate/vDSP.
  3. Manual: user scrubs to a known moment ("tap when you cross start/finish").

## 5. Data model (sketch)

```
Session: id, date, trackId?, mode(track|autocross|canyon), carId, tier, notes
Channel: sessionId, name(gps.lat, gps.lon, gps.speed, imu.ax..., obd.rpm,
         obd.throttle, obd.speed, derived.gear, derived.speed_fused, ...),
         samples[(t, value)], source, quality
Lap:     sessionId, index, t_start, t_end, time, valid(bool)
Corner:  lapId, index, t_entry, t_apex, t_exit, geometry(radius, length),
         metrics(v_min, brake_point, coast_ms, throttle_point, peak_g...)
Finding: sessionId, detectorId, cornerRef?, severity, est_gain_s,
         evidence(json), advice_params(json), videoTimestamp?
Track:   id, name, start/finish line (2 GPS points), corner map, ref data
Car:     id, make/model/year, gear ratios, final drive, redline, weight
VideoAsset: sessionId, url(local), syncOffset, syncMethod, confidence
```

Storage: **GRDB (SQLite)**. Raw channel samples in compact binary blobs or sidecar files; metadata in tables. A full session ≈ single-digit MB.

## 6. Processing pipeline (on-device, post-session)

Runs in seconds after "End session" or import:

1. **Sensor fusion:** Kalman filter GPS (low-rate, absolute) + IMU (high-rate, relative) → fused speed/position/heading at ~20Hz equivalent + per-sample confidence. This is what makes Tier 1 phone-GPS usable. Canyon mode leans harder on IMU (multipath/tree cover).
2. **Track matching:** match GPS trace against track DB (launch set: curated SoCal tracks — Streets of Willow, Big Willow, Buttonwillow, autocross mode w/o fixed map). No match → generic/canyon mode with auto-segmentation.
3. **Lap segmentation:** start/finish line crossing detection; flag out-laps, in-laps, traffic-compromised laps (anomalous slow sectors) as invalid for comparison.
4. **Corner segmentation:** curvature of fused path (θ̇ vs distance); merge into corner objects with entry/apex/exit phases. Curated tracks ship with named corners; unknown roads get auto-numbered corners.
5. **Detector suite** → structured Findings (see 02-coaching-engine.md).
6. **Prioritizer:** rank findings by estimated time gain × repeatability (recurring on N laps beats one-off); emit top 3 + corner grades + technique scores + one drill.
7. **(Optional, cloud)** Findings JSON (KBs, no video, no raw GPS trail if user prefers) → LLM → natural-language debrief narrative. Local template-based fallback text when offline/opted out.

## 7. Presentation layer

- **Session debrief screen:** the report (see sample-coaching-report.md) — summary, top 3, corner table, scores, drill.
- **Video player:** AVFoundation playback + telemetry overlay (speedo, RPM bar, G-circle, pedal traces) rendered live from channels — no re-encode needed for in-app viewing. Export w/ burned-in overlay = background render job (share feature, v1.1).
- **Deep links:** every Finding stores a video timestamp → "Watch: Lap 9, 0:47".
- **Progress view:** technique scores across sessions at same track; consistency trends.

## 8. Tech stack summary

- Swift + SwiftUI, iOS 17+
- CoreBluetooth (OBD2, RaceBox), CoreLocation, CoreMotion, AVFoundation
- Accelerate/vDSP (FFT for audio-RPM, filtering), simd
- GRDB/SQLite local store
- Cloud (Phase 1b): thin API → LLM for narratives; auth optional until community features

## 9. Roadmap

- **M1 (MVP):** live capture (phone+OBD) → pipeline → debrief report. One car profile (ND2), curated Streets of Willow + Big Willow, generic mode elsewhere. No cloud.
- **M1.5:** video import + audio-RPM sync + overlay player + deep links. LLM narratives (opt-in cloud).
- **M2 (Tier 2):** RaceBox Mini S live + file imports (RaceChrono/VBO), line/apex coaching, more track maps.
- **M3:** community reference laps (anonymized), car library beyond MX-5.
- **M4 (Tier 3):** real-time audio coaching.

## 10. Open questions

- Track DB sourcing: build corner maps by driving them ourselves + tracing satellite imagery? Licensing of existing track map datasets?
- Autocross: courses are ephemeral (cones, new layout every event) → pure self-reference + auto-segmentation; needs its own UX.
- Thermal/battery: 25-min session with GPS+IMU+BLE+screen-off recording — measure real drain on track day.
- App Store review: dashcam/telematics apps are fine; ensure canyon positioning stays education-framed.
