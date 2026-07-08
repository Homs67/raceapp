# Data Capabilities — iPhone + OBD2 (Tier 1) (v0.1)

Everything we can technically capture with **just a phone + the Veepeak OBDCheck BLE+**, and what each signal is good for. This is the raw-material inventory that the design brief and detector suite draw from. Tier 2 (RaceBox 25Hz GPS) additions noted at the end.

---

## 1. Phone sensors

| Source | Signal | Rate / quality | Coaching value |
|---|---|---|---|
| CoreLocation (GPS) | lat/lon, altitude, speed, course, **per-fix horizontal accuracy** | ~1Hz, ±5–15m raw | Position on track, lap/sector timing (±~1s at 1Hz — fusion improves this), track matching, braking-point distance (with stated uncertainty) |
| CoreMotion accelerometer | 3-axis acceleration | 100Hz | Longitudinal G (braking/accel), lateral G (cornering), combined-G friction circle, braking commitment (G rise rate) |
| CoreMotion gyroscope | 3-axis rotation rate | 100Hz | Yaw rate → corner detection/curvature, rotation vs. steering smoothness, slide/oversteer signature (yaw vs. lateral-G mismatch) |
| CoreMotion attitude/gravity | orientation quaternion, gravity vector | 100Hz | Mount calibration, gravity compensation, banking/camber estimation on canyon roads |
| CMAltimeter (barometer) | relative altitude | ~1Hz, sub-meter relative | Elevation profile — big for canyon mode (grade-aware braking/accel expectations); GPS-altitude sanity check |
| Magnetometer | heading | ~50Hz, noisy in-car | Weak signal (car body distorts field) — tie-breaker for heading init only |
| Microphone | audio track | 44.1kHz | **Engine RPM via FFT** — video↔telemetry sync, OBD-dropout backup RPM channel |
| Camera (or GoPro import) | video | 30–60fps | Delivery medium: findings deep-link into footage with overlay |
| Thermal/battery state | device health | event | Session-health telemetry; warn before thermal shutdown on hot track days |

## 2. OBD2 channels (Veepeak BLE+, ND2)

Full detail in 03-obd2-integration.md §8. Summary:

- **Fast (5–15Hz shared):** RPM, vehicle speed, throttle position, (accelerator pedal position if supported)
- **Slow (~0.2Hz):** coolant temp, oil temp (if supported), intake air temp, ambient temp, fuel level, barometric pressure, engine load, battery voltage
- **Per session:** VIN, DTC/MIL status
- **Not available:** brake, steering, wheel speeds, clutch switch — covered by IMU/GPS

## 3. Derived channels (the actual product)

Fusion and inference — none of these exist in any single sensor:

| Derived channel | Built from | Powers |
|---|---|---|
| **Fused speed/position/heading @ ~20Hz** | Kalman: GPS (absolute, slow) + IMU (relative, fast) + OBD speed (sanity) | Everything positional: lap times, corner segmentation, braking points, deltas |
| **Current gear** | OBD speed/RPM ratio vs. ND2 gear table | Shift analysis, rev-match targets |
| **Shift & clutch events** | RPM–speed ratio discontinuities | D3 rev-match, shift-point stats |
| **Rev-match quality** | blip RPM vs. required RPM (from wheel speed × target gear ratio) | D3 — Catalyst can't do this |
| **Brake-pressure proxy** | longitudinal G (IMU, gravity/grade-compensated via barometer) | D2 braking commitment, brake-dip-during-blip |
| **Coast time** | brake-release (G fade) → throttle-on (OBD) gap | D1 — top novice time-loss |
| **Corner curvature & phases** | fused path θ̇ vs. distance | Corner objects: entry/apex/exit |
| **Friction-circle utilization** | √(lat²+long²) vs. physics ceiling | D5 grip %, trail-braking L-shape detection |
| **Jerk (smoothness)** | da/dt from IMU | D7 smoothness score |
| **Audio RPM** | mic/video FFT | video sync, OBD backup |
| **Elevation profile** | barometer + GPS altitude | grade-corrected G analysis, canyon segmentation |
| **Lap/sector times** | fused position × track start/finish geometry | headline numbers, D6 consistency |
| **Conditions record** | ambient/intake temps, baro, (weather API later) | session comparability, grip-model context |

## 4. What this inventory supports (Tier 1, no extra hardware)

Every MVP detector D1–D7 is fully covered:
coasting (D1), braking point & commitment (D2, with stated GPS uncertainty), rev-match/heel-toe quality (D3), throttle application & hesitation (D4), grip utilization (D5), consistency & fatigue (D6), smoothness (D7) — plus session health (temps), fuel burn, and video-linked evidence for all of it.

**Honest limits at Tier 1:** braking-point distance carries ±5–15m GPS uncertainty (phrase advice against physical references, per 02-coaching-engine D2); racing-line/apex-position coaching is **not** credible at 1Hz GPS — that's the Tier 2 unlock, and the report should say so (graceful-degradation upsell).

## 5. Tier 2 additions (RaceBox Mini S, for reference)

25Hz GPS ±<1m (RTK-grade fixes), built-in 100Hz IMU → precise braking markers, racing line vs. track edges, apex position, trustworthy sector deltas → unlocks D8–D10.
