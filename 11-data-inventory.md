# Data Inventory — per device (v1.0, 2026-09-11)

Everything raceApp can capture, mapped to the **device that provides it**. Ground-truthed
against the code: channel model (`SessionKit/ChannelId.swift`), OBD PIDs
(`ObdKit/ObdChannel.swift`), the verified ND CAN map (`ObdKit/CanSignal.swift`), and
RaceBox decode (`RaceBoxKit/RaceBoxDataMessage.swift`). Supersedes the Tier-1 sketch in
`04-data-capabilities.md`.

## The devices stack — they are not alternatives

A real setup is **iPhone (always) + one OBD adapter (± CAN) + optionally a RaceBox**. Each
row below says which of the four "configs" contributes a signal:

| Config | What it is | Adds over the phone |
|---|---|---|
| **A · iPhone alone** | CoreLocation + CoreMotion + baro + mic + camera | baseline — phone-only capture |
| **B · + OBD-II (no CAN)** | ELM327 polling standardized emissions PIDs | engine/health data, any car |
| **C · + OBD-II with CAN** | same adapter, ELM327 monitor mode + per-car map (MX-5 ND) | steering, brake, pedal, wheel speeds — at 50–105 Hz |
| **D · + RaceBox Micro/Mini** | external 25 Hz GNSS + IMU dongle | precise position/line, true 25 Hz motion, timing |

Positional/motion data has a **quality ladder**: phone GPS (1 Hz) < RaceBox (25 Hz). Engine
data has a **richness ladder**: OBD PIDs (polled, universal) < broadcast CAN (fast, per-car).

---

## A · iPhone (CoreLocation + CoreMotion + more)

**What we use today** (`PhoneSensorSuite`, published to the bus):

| Signal | Channel | Rate | Range / accuracy | Powers |
|---|---|---|---|---|
| GPS lat/lon | `gps.lat` `gps.lon` | ~1 Hz | ±5–15 m raw | position, lap/sector, track match |
| GPS altitude | `gps.altitude` | ~1 Hz | ±10–30 m | elevation (weak vs baro) |
| GPS speed | `gps.speed` | ~1 Hz | good when moving | speed fallback, fusion sanity |
| GPS course | `gps.course` | ~1 Hz | degrees | heading (only while moving) |
| GPS accuracies | `gps.hAcc` `gps.vAcc` `gps.speedAcc` | ~1 Hz | ±m, ±m/s | **honesty channels** (stated uncertainty) |
| GPS wall time | `gps.wallTime` | ~1 Hz | unix epoch | clock audit / UTC anchor |
| Accel (user, g-separated) | `imu.ax/ay/az` | 100 Hz | ±device limit | long/lat G, friction circle, jerk |
| Gyro | `imu.yawRate` `imu.pitchRate` `imu.rollRate` | 100 Hz | rad/s | corner/curvature, rotation, slide |
| Heading (fused) | `imu.heading` | 100 Hz | degrees | heading when stationary |
| Barometer | `baro.relAltitude` | ~1 Hz | sub-meter relative | elevation profile, grade |
| Device battery | `device.battery` | event | 0–1 | session-health telemetry |
| Device thermal | `device.thermal` | event | 0–3 | warn before thermal shutdown |

**What we could add on top (available, not yet wired):**

| Source | Signal | Value |
|---|---|---|
| **Microphone** | engine RPM via FFT | OBD-dropout backup RPM, video↔telemetry sync |
| **Camera / GoPro import** | 30–60 fps video | overlay medium — findings deep-link into footage |
| Magnetometer | heading | weak (car body distorts) — heading-init tie-breaker only |
| CoreMotion attitude | orientation quaternion, gravity | already used for mount leveling / car-frame G |

**Honest limits:** 1 Hz GPS means ~30 m between fixes at 60 mph → lap timing carries ±0.3–0.5 s
and **no credible apex/line precision**. That's the whole reason config D (RaceBox) exists.

---

## D · RaceBox Micro (external GNSS + IMU) — the motion-truth device

Pure GNSS + IMU logger over BLE (RaceBox protocol + NMEA). **Does NOT read OBD/engine/CAN** —
2-pin 3.5–16 V power only (wire to OBD 12 V or USB 5 V). Full 80-byte message decoded in
`RaceBoxDataMessage.swift`:

| Signal | From message | Rate | Spec | Powers |
|---|---|---|---|---|
| Position lat/lon | i32 /1e7 | **25 Hz** | multi-GNSS (GPS/GLONASS/Galileo/BeiDou) | precise line, apex, sector deltas |
| Altitude WGS + MSL | i32 /1000 | 25 Hz | mm resolution | elevation (real Corkscrew drop) |
| h/v accuracy, speed acc, heading acc | u32 | 25 Hz | ±m / ±m/s / ±° | honesty channels |
| Speed | i32 mm/s | 25 Hz | — | true speed trace |
| Heading | i32 /1e5 | 25 Hz | valid-flag gated | line/heading at rate |
| Fix status, satellites, PDOP | bytes | 25 Hz | 3D-fix + valid flag | data-quality gating |
| 3-axis G-force | i16 milli-g | 25 Hz | **±8 g**, 0.001 g, 1 kHz internal | friction circle, braking |
| 3-axis rotation | i16 centi-°/s | 25 Hz | **±320 °/s**, 0.02 °/s | yaw/pitch/roll |
| Input voltage | byte /10 | 25 Hz | 3.5–16 V | power health (Micro has no battery) |
| GPS UTC timestamp | y/m/d/h/m/s + ns | per fix | ns-corrected | authoritative clock |

**Unlocks:** trustworthy sector deltas, racing line vs. track edges, apex position — the Tier-2
detectors (D8–D10 in `02-coaching-engine.md`). It replaces the phone's *position/motion* half;
it does **not** replace OBD (no engine data).

---

## B · OBD-II standard PIDs (no CAN) — any car, via ELM327 polling

Request/response emissions PIDs (`ObdChannel.swift`). Works on any post-1996 car. Effective
**~5–15 Hz shared** across the fast loop (multi-PID request), ~0.2 Hz slow loop.

**Fast loop (coaching channels):**

| PID | Channel | Powers |
|---|---|---|
| 0x0C | `obd.rpm` | rev-match, gear derivation, shift points, audio-sync anchor |
| 0x0D | `obd.speed` (km/h, 1-km/h quantized) | gear derivation, GPS/IMU fusion sanity |
| 0x11 | `obd.throttle` | coast (D1), throttle application (D4) |
| 0x49 | `obd.acceleratorPedal` (if supported) | truer driver input than 0x11 |

**Slow loop (context / health):** `obd.coolantTemp` 0x05, `obd.oilTemp` 0x5C, `obd.intakeAirTemp`
0x0F, `obd.ambientTemp` 0x46, `obd.fuelLevel` 0x2F, `obd.barometricPressure` 0x33,
`obd.engineLoad` 0x04, `obd.controlModuleVoltage` 0x42, `obd.timingAdvance` 0x0E,
`obd.manifoldPressure` 0x0B, `obd.mafRate` 0x10.

**One-shot per session:** VIN (0902), DTC/MIL status (0101), supported-PID bitmap.

**Explicitly NOT available at this layer:** brake, steering, individual wheel speeds, clutch —
covered by the IMU (B/A) or by CAN (C).

---

## C · OBD-II with CAN (MX-5 ND map) — the differentiator

Same adapter, **ELM327 monitor mode** listening to the raw 500 kbps HS-CAN broadcast, decoded
by the per-car map in `CanSignal.swift` (`CanSignalMap.mazdaND`). **50–105 Hz** vs ~7.5 Hz OBD
polling — and it exposes signals OBD-II never can. Equations from the RaceChrono community map,
tested on a 2019 ND RF.

| Channel | Frame | Decode | Status |
|---|---|---|---|
| `can.steering` (°, + = right) | **0x086** | `(16000 − u16)·0.1` | ✅ verified (variable ratio; centering varies by year) |
| `can.brake` (%) | **0x078** | bits 28–39 → `(raw−156)/2.56` clamp | ✅ verified |
| `can.accelPedal` (%) | **0x202** | `byte4 / 2.5` | ✅ verified |
| `can.rpm` | **0x202** | `u16 / 4` | ✅ verified (matches OBD 0x0C) |
| `can.wheelSpeed` (km/h, 4-wheel avg) | **0x4B0** | four u16 `(raw−10000)·0.01`, standstill = 0.00 | ⚠️ pending on-car verification |

**Why this matters for coaching:** steering, brake, and pedal are the **three driver inputs**
(see the earlier coaching discussion) — the exact channels OBD-II can't give and that the app
otherwise approximates from the IMU. CAN gives them *directly*, at high rate. Individual wheel
speeds (0x4B0) additionally enable slip/lock detection. This is per-model and proprietary — each
car needs its own map (bundled + community/DBC import + the guided auto-map idea).

---

## Derived channels (computed, not sensed — from A/B/C/D)

Fusion and inference — none of these live in a single sensor:

| Derived | Built from | Powers |
|---|---|---|
| **Car-frame G** `car.latG` `car.longG` | IMU leveled by gravity + aligned on first accel | gauges, friction circle, honest G |
| **Fused position/speed ~20 Hz** | Kalman: GPS (abs) + IMU (fast) + OBD/CAN speed (sanity) | everything positional |
| **Current gear** | speed/RPM ratio vs ND gear table (`GearEstimator`) | shift analysis, rev-match targets |
| **Lap / sector times** | fused position × start-finish gate (`LapTimer`) | headline numbers, consistency |
| **Drag runs** | speed integrated from standstill (`DragMeter`) | 0–60 / 0–100 / ¼-mile |
| **Racing line + target speed** | centerline curvature (`RacingLine`/`TrackNav`) | 3D nav face, brake prompts |
| **Rev-match quality, coast time, jerk** | CAN/OBD + IMU per corner phase | D1–D7 detectors |
| **Audio RPM** | mic FFT | OBD backup, video sync |

---

## Fusion picture — best source per quantity, with fallback chain

For each high-value quantity, which config wins and what degrades to:

| Quantity | Best | Fallback → | Worst-case |
|---|---|---|---|
| **Position / line** | D RaceBox 25 Hz | → A phone GPS 1 Hz | (none — needs GPS) |
| **Speed** | D RaceBox → C CAN wheels → B OBD 0x0D | → A GPS | GPS only |
| **Lateral / long G** | D RaceBox ±8 g 25 Hz | → A phone IMU 100 Hz | phone IMU |
| **Steering** | C CAN 0x086 | → (none direct) → A yaw-rate *proxy* | yaw-rate proxy only |
| **Brake** | C CAN 0x078 | → A IMU long-G *proxy* | IMU proxy |
| **Throttle / pedal** | C CAN 0x202 | → B OBD 0x11/0x49 | OBD polled |
| **RPM** | C CAN 0x202 (105 Hz) | → B OBD 0x0C | → A audio FFT |
| **Elevation** | A baro (relative) + D MSL alt | → GPS altitude | GPS alt |
| **Wheel slip / lock** | C CAN 0x4B0 (⚠) | → (none) | not available |

**Reading it:** without CAN, steering and brake are only ever *proxies* (yaw-rate, IMU G).
Without a RaceBox, position/line is 1 Hz — fine for "am I improving," not for apex coaching.
The strongest rig is **iPhone + CAN-capable OBD adapter + RaceBox**: precise line (D), true
driver inputs (C), full engine/health (B), and video/audio (A).

## Capability by device — isolated (what each device provides on its own)

The app always runs on the **phone**; OBD-II and RaceBox are accessories. These columns are
**isolated** (not cumulative): each shows what that one source provides alone. 🟠 = provides it ·
— = does not. Key honesty fixes: OBD-II has **no** GPS/IMU/elevation; the iPhone **cannot**
measure steering angle or brake position (yaw-rate is the car's *reaction*, not the driver's
input); steering/brake are **CAN-only**.

### Raw data — by device
| Data | iPhone | OBD-II | OBD-II + CAN | RaceBox |
|---|:--:|:--:|:--:|:--:|
| Position / track map | 🟠 1 Hz | — | — | 🟠 25 Hz |
| Speed | 🟠 GPS | 🟠 wheel | 🟠 wheel | 🟠 Doppler |
| Heading | 🟠 | — | — | 🟠 |
| Altitude / elevation | 🟠 baro | — | — | 🟠 |
| Position accuracy (±m) | 🟠 | — | — | 🟠 |
| Fix quality (sats / PDOP) | — | — | — | 🟠 |
| G-force (lateral + longitudinal) | 🟠 | — | — | 🟠 ±8 g |
| Vertical G | 🟠 | — | — | 🟠 |
| Rotation (yaw / pitch / roll rate) | 🟠 | — | — | 🟠 ±320°/s |
| **Steering angle** | — | — | 🟠 | — |
| **Brake input** | — | — | 🟠 | — |
| Throttle / accelerator pedal | — | 🟠 | 🟠 faster | — |
| Individual wheel speeds | — | — | 🟠 | — |
| RPM | — | 🟠 | 🟠 faster | — |
| Engine load | — | 🟠 | 🟠 | — |
| Timing advance | — | 🟠 | 🟠 | — |
| MAP / MAF (airflow) | — | 🟠 | 🟠 | — |
| Coolant temp | — | 🟠 | 🟠 | — |
| Oil temp | — | 🟠 | 🟠 | — |
| Intake air temp | — | 🟠 | 🟠 | — |
| Ambient temp | — | 🟠 | 🟠 | — |
| Fuel level | — | 🟠 | 🟠 | — |
| System / battery voltage | — | 🟠 car | 🟠 car | 🟠 input |
| Barometric pressure | 🟠 baro | 🟠 PID | 🟠 PID | — |
| VIN / car identity | — | 🟠 | 🟠 | — |
| DTC / check-engine | — | 🟠 | 🟠 | — |
| Phone battery / thermal | 🟠 | — | — | — |
| Video (dash cam) | 🟠 | — | — | — |
| Audio / engine sound | 🟠 | — | — | — |

### Derived & app features — what each needs
Computed from the raw data above, so listed by **requirement** rather than one device.
Status: Now / Beta / Future.

| Feature | Status | Needs |
|---|---|---|
| Gear | Now | RPM + speed → OBD (or CAN) |
| Friction circle / peak-G | Now | IMU → iPhone or RaceBox |
| Lap & sector timing | Now | position → iPhone (coarse) or RaceBox (precise) |
| Drag runs (0–60 / ¼-mi) | Now | speed → OBD ok, RaceBox best |
| Shift lights / shift-point analysis | Now | RPM → OBD or CAN |
| 3D nav + racing line | Now | position → iPhone ok, RaceBox precise |
| Precise line / apex / true sector deltas | Beta | 25 Hz position → **RaceBox** |
| Ghost lap (position replay) | Future | position + a recorded lap |
| Slip / traction · lock-up | Future | CAN wheel speed **+** GNSS ground speed |
| Trail-braking · brake-commitment | Future | **CAN** (brake + steering) |
| Rev-match / heel-toe quality | Future | RPM + CAN pedal/brake |
| Coast-time detection | Future | throttle (OBD) + brake (CAN) |
| Consistency / corner grades | Future | repeatable position → RaceBox best |
| Smoothness / grip-utilization score | Future | IMU → iPhone or RaceBox |
| Slide / oversteer detection | Future | IMU yaw vs lateral-G → iPhone or RaceBox |
| Video telemetry overlay | Future | phone camera + any data |
| AI debrief / findings / drills | Future | any captured data (richer = better) |
| Auto CAN signal mapping (AI) | Future | **CAN** |

Pure-software, device-independent (off the matrix): session logging, CSV export, cloud sync,
leaderboards, sharing, CarPlay, Apple Watch.

## Honest gaps

- **Wheel speed (0x4B0)** is unverified on-car — the standstill-reads-0.00 signature is the check.
- **CAN is MX-5-ND only** today; every other car needs its own map.
- **Gateway'd cars** (many post-2018) firewall the OBD port — config C may be impossible there.
- **ELM327 monitor mode drops frames** on a busy bus — a dedicated CAN dongle would raise C's ceiling.
- **RaceBox gives no engine data** — it is not a substitute for B/C, only for the motion half of A.
