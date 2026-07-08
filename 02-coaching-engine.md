# Coaching Engine Spec (v0.1)

Companion to 01-architecture.md. Defines the detector suite, references, scoring, and advice generation. Target user: beginner→intermediate amateur (HPDE, autocross, time attack, canyon). Design inputs: HPDE data-coaching best practices, VRS/Track Titan-style corner-phase analysis, Garmin Catalyst criticisms (vague advice, average-lap comparison, no OBD).

---

## 1. Core loop

```
Channels ──▶ Corner metrics ──▶ Detectors ──▶ Findings ──▶ Prioritizer ──▶ Report
                    ▲                              │
                    └── Reference (best lap / physics / community) ──┘
```

Every Finding must be: (a) **evidenced** (numbers from this session), (b) **measurable** ("blip to 5,500–5,800 rpm", not "rev match better"), (c) **referenced** (compared to something explicit), (d) **actionable next session** (one concrete change), (e) **video-linked** when video exists.

## 2. References (what we compare against)

1. **Self-best (MVP, day one):** best valid lap this session + personal best at this track. NEVER coach against the average lap.
2. **Physics-lite (MVP, enables day-one coaching with zero history):** from corner geometry, v_max = √(μ·g·r) with conservative μ per surface/tire class (ND2 on 200TW ≈ 1.0–1.05 on track). Yields "you're using X% of available grip in T3" without any reference lap. Also powers canyon mode.
3. **Community reference (M3):** anonymized fast laps, same car class + track. Long-term moat.

## 3. MVP detector suite (Tier 1 data: fused GPS/IMU + OBD)

### D1 — Coast detection  *(top novice time-loss)*
- Signal: gap between brake release (long. decel < 0.15g fading) and throttle application (obd.throttle > ~10%) per corner entry.
- Threshold: flag gaps > 0.5s; severity scales with duration × frequency across laps.
- Advice params: corner, avg gap, best-lap gap, target (<0.5s).
- Est. gain: coast_time × ~0.4 (empirical fraction recoverable) summed over laps — refine with testing.

### D2 — Braking point & commitment
- Signals: braking start distance-to-corner (from fused position), peak long. G, time-to-peak-pressure (G rise rate).
- Compare braking start vs self-best lap; flag "early + soft" pattern (start >15m earlier AND peak G < best-lap peak − 0.1g).
- Tier 1 caveat: report distance uncertainty from GPS confidence (e.g. ±8m); phrase advice with physical references ("one car length past the 300ft board"), not raw meters.
- Rule of thumb for gain estimate: ~10m of braking distance ≈ ~0.15s (validate per corner speed).

### D3 — Rev-match / downshift quality  *(manual cars; OBD-unique, Catalyst can't do this)*
- Signals: during braking zones, detect downshift (derived.gear step) + blip (RPM spike while clutch presumed in).
- Score: |blip_rpm − required_rpm| where required_rpm = wheel_speed × new_gear_ratio × final_drive. Flag chronic under/over-blip.
- Secondary: **brake pressure dip during blip** — long. G drop >15–20% during heel-toe window = driver easing brakes while blipping (near-universal amateur flaw).
- Advice params: target blip RPM band per shift per corner.

### D4 — Throttle application & hesitation
- Signals: throttle-on point after apex (time & position), mid-corner lifts (throttle drops >20% then recovers within 1s), application smoothness (dTPS/dt spikes).
- Compare throttle-on point vs self-best; every 0.1s earlier compounds down the following straight — weight corners leading onto straights higher (corner importance weighting per track map).

### D5 — Grip utilization (friction circle)
- Signal: total G = √(lat² + long²) through corner phases vs physics-lite ceiling and vs self-best.
- Novice signature: "L-shaped" G usage (brake, THEN turn, nothing combined) vs blended arc (trail braking). Score entry-phase combined-G.
- Reported as percentage: "T3 entry: using 71% of available grip."

### D6 — Consistency & fatigue
- Lap-time variance on valid laps; rolling trend across session (detect late-session fall-off → stint-length / hydration advice).
- Corner-level repeatability: std-dev of v_min and braking point per corner. High variance corner = coach consistency BEFORE speed there.
- Consistency score 0–100 on report.

### D7 — Smoothness (IMU jerk analysis)
- RMS jerk (da/dt) lateral + longitudinal, normalized by pace. Trend across sessions. Feeds "Smoothness" score.

### Post-MVP detectors (Tier 2 / M2)
- D8 line & track-width usage (needs 10/25Hz GPS + track edges): early apex, pinched exit, unused width.
- D9 apex position vs reference; entry/apex/exit phase time deltas per corner.
- D10 shift-point optimization vs power curve (upshift RPM vs ND2 dyno curve).

## 4. Prioritizer

- Rank Findings by `est_gain_s × repeatability_factor` (recurring-on-most-laps > one-off) with safety overrides (e.g., D6 high variance in a fast corner outranks raw time gain — coach control before speed).
- Emit exactly **3 priorities**, corner-by-corner grade table (A–F from phase metrics vs reference), 5 technique scores (braking, throttle, shifting, line, smoothness) with per-session deltas, and **1 drill** for next session.
- Never repeat the same #1 priority more than 2 sessions in a row without acknowledging progress explicitly (progress framing matters for amateurs).

## 5. Advice generation

- Detectors output structured `Finding` objects (JSON). Two rendering paths:
  1. **Local templates** (offline/default): parameterized sentences per detector, tuned tone — direct, encouraging, zero jargon-shaming.
  2. **LLM narrative** (opt-in cloud): Findings JSON + track/corner names + session context → conversational debrief + Q&A chat ("why did I lose time in T4?"). LLM NEVER invents numbers — it only phrases what detectors computed. Guardrail: numeric claims must match Finding fields.
- Every report footer: closed-course education disclaimer.

## 6. Mode differences

| | Track | Autocross | Canyon |
|---|---|---|---|
| Reference | self-best + physics + (later) community | self-best within event + physics | physics-lite + technique quality ONLY |
| Segmentation | track DB corner map | auto-segmentation per run | auto-segmentation per road section |
| Framing | lap time gains | run time + cone-safe technique | smoothness, grip margin, technique — NEVER "go faster"; emphasize margin-for-error metrics (e.g., % grip in reserve as a POSITIVE) |
| Extra | corner importance weights | launch analysis (D-launch: RPM, bog/spin detection) | GPS degraded → IMU-heavy fusion; report confidence |

## 7. Validation plan

- Ground truth: founder's own sessions at Streets of Willow with RaceBox Mini S + Veepeak simultaneously → does Tier 1 (phone GPS) detector output match Tier 2 conclusions? Acceptable disagreement bounds per detector.
- Sanity: run detectors on an experienced driver's lap — should produce few/low-severity findings (false-positive check).
- Advice quality: blind-review detector findings with a human HPDE instructor for 3–5 sessions; tune thresholds.
