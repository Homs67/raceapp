# OBD2 Integration Plan — Veepeak OBDCheck BLE+ (v0.1)

Companion to 01-architecture.md §4.1. Target adapter: **Veepeak OBDCheck BLE+** (our baseline "slowest common adapter"). Target car: 2022 MX-5 ND2 6MT (CAN, ISO 15765-4).

Sources: OBDCheck BLE+ user manual v3.2606 + ELM327 protocol knowledge. Facts confirmed by the manual are marked ✓; anything marked ⚠ must be verified empirically in the discovery spike (§6).

---

## 1. Device facts

- ✓ **Bluetooth LE on iOS** — no system pairing; the app connects directly via CoreBluetooth. (Classic BT exists but is Android-only territory; we ignore it.)
- ✓ Advertises as **`VEEPEAK`**.
- ✓ **ELM327 v2.2 AT command set** (the non-Plus model is v1.4 — one reason to require/recommend the Plus).
- ✓ **One app/connection at a time** — if RaceChrono or Car Scanner is connected, we can't be. Surface this in connection-failure UX.
- ✓ **Standard OBD-II (emissions) PIDs only.** No ABS, no brake pressure, no steering angle, no wheel speeds, no TPMS. This is fine — our architecture already assumes braking comes from IMU/GPS, not the car.
- ✓ Data rate depends on vehicle protocol; CAN (our ND2) is the fastest class. Manual's own tip: poll fewer PIDs for more speed — exactly our minimal-PID design.
- ⚠ GATT layout: Veepeak-class adapters typically expose a vendor UART service (commonly `FFF0` with `FFF1` notify / `FFF2` write, or `FFE0`/`FFE1`). Not documented in the manual — must be discovered on real hardware (§6).

## 2. Connection flow (CoreBluetooth)

State machine:

```
Idle → Scanning → Connecting → DiscoveringGATT → InitializingELM → Polling
                                                      ↑                │ drop
                                                      └── Reconnecting ┘ (backoff, auto-resume)
```

1. **Scan.** `CBCentralManager.scanForPeripherals` — the adapter may not advertise its service UUID, so scan broadly and filter by name `VEEPEAK` (also match user-selected peripheral; store its `identifier` for instant reconnect next session).
2. **Connect + discover.** Discover all services/characteristics; pick the characteristic pair: one with `.notify`, one with `.write`/`.writeWithoutResponse`. Log the full GATT tree in dev builds (feeds §6 and future adapter support).
3. **Subscribe** to the notify characteristic. All ELM I/O is ASCII over these two characteristics.
4. **Write protocol:** commands are ASCII terminated with `\r`. Responses stream in notify chunks; **accumulate until the `>` prompt character** — never assume one notification = one response. BLE writes may need chunking to ≤20 bytes (⚠ check negotiated MTU; modern iOS usually negotiates 185+).

## 3. ELM327 init sequence

Sent once after connect (each ~50–200ms):

```
ATZ          reset (returns "ELM327 v2.2")
ATE0         echo off
ATL0         linefeeds off
ATS0         spaces off (halves response bytes)
ATH0         headers off
ATSP6        force ISO 15765-4 CAN 11bit/500k (ND2) — skips slow auto-detect
ATAT2        aggressive adaptive timing
0100         wake ECU + fetch supported-PID bitmap
```

Notes:
- `ATSP6` is a **per-car setting**; default profile uses `ATSP0` (auto) for unknown cars, but the car profile stores the discovered protocol and pins it thereafter.
- On first connect to a new car, run the **supported-PID discovery** (`0100`, `0120`, `0140`, `0160`) and persist the capability bitmap in the Car profile.
- Handle `NO DATA`, `STOPPED`, `CAN ERROR`, `UNABLE TO CONNECT` as distinct states (ignition off vs. adapter unplugged vs. mid-command interruption).

## 4. Polling strategy

Two loops, matching 01-architecture §4.1:

**Fast loop (continuous, target 5–15Hz effective):**
- On CAN we can request **multiple PIDs in one message**: `010C0D11` → RPM + speed + throttle in a single round-trip. This roughly triples effective rate vs. sequential polling. ⚠ Verify the ND2 ECU answers multi-PID requests; fall back to sequential if not.
- Append the **expected-response-count digit** (e.g. `010C1` sequential form) so the ELM returns immediately instead of waiting out its response timer — the single biggest latency win on ELM clones.
- Timestamp each sample **on receipt** using the monotonic clock, mapped to UTC once per session; record round-trip latency per request so processing can model the (speed, RPM) staleness.

**Slow loop (every ~5s, interleaved):**
- `0105` coolant, `010F` intake air temp, `015C` oil temp (⚠ if ND2 supports), `012F` fuel level, `0146` ambient, `0142` battery voltage.

**Session bookends:** on connect, read `0101` (MIL/DTC status) and VIN (`0902`) for the session record; no DTC clearing — we're read-only.

## 5. Robustness requirements

- **Reconnect with backoff** (0.5s → 5s cap), auto-resume polling, and mark the gap in the channel (dropouts are expected; the audio-RPM channel is the analysis-time backup per 01-architecture §4.3.2).
- **Append-only writes** of raw samples as they arrive (crash loses seconds, not the session).
- Survive backgrounding: `bluetooth-central` background mode keeps the BLE session alive with the screen off.
- Treat the adapter as hostile: garbage bytes, echoed prompts, interleaved `SEARCHING...` lines. The response parser is a tolerant line-accumulator, fuzz-tested with recorded real transcripts.

## 6. Discovery spike (first milestone, ~1 day with car in driveway)

A single debug screen, engine running:
1. Scan → connect → dump full GATT tree (resolves all ⚠ above).
2. Run init sequence; log every raw byte both directions to a file.
3. Stream RPM/speed/throttle to screen; **measure sustained Hz** for sequential vs. multi-PID polling.
4. Run supported-PID discovery; record which PIDs the ND2 actually answers (esp. oil temp `5C`, accelerator pedal `49/4A`, MAP `0B`).
5. Blip throttle in neutral, note visual lag → data for latency model.

Output: a facts file (`obd-nd2-facts.md`) + raw transcripts that become parser test fixtures. Everything downstream (`ObdKit` module API, polling scheduler) is written against these facts.

## 7. Module shape

`ObdKit` (part of the pure-Swift processing package's sibling capture layer):
- `ObdTransport` protocol (BLE impl + **replay impl fed by spike transcripts** — enables all development without the car)
- `Elm327Session` — init, command queue, response parsing, error states
- `PidPoller` — fast/slow loop scheduler → emits `(t, pid, value)` into the standard Channel model
- `PidDecoder` — pure functions, unit-tested: `410C1AF8` → 1726 rpm, etc.

## 8. What data we get from this adapter (ND2, standard OBD-II)

**Fast loop (the coaching channels):**

| PID | Channel | Rate | Used by |
|---|---|---|---|
| 0x0C | RPM (¼-rpm resolution) | fast | D3 rev-match, gear derivation, shift points, audio-sync anchor |
| 0x0D | Vehicle speed (1 km/h integer — quantized) | fast | gear derivation, GPS/IMU fusion sanity channel |
| 0x11 | Throttle position % | fast | D1 coast, D4 throttle application/hesitation |
| 0x49/0x4A | Accelerator pedal position (⚠ if supported) | fast | truer driver-input signal than 0x11 (drive-by-wire) |

**Slow loop (context/health):**

| PID | Channel | Used for |
|---|---|---|
| 0x05 | Coolant temp | session health, heat-soak trend across stints |
| 0x0F | Intake air temp | conditions log |
| 0x5C | Oil temp (⚠) | track-day health headline metric |
| 0x2F | Fuel level | fuel-burn per session, weight delta note |
| 0x46 | Ambient temp | conditions log (grip model context) |
| 0x33 | Barometric pressure | conditions log |
| 0x04 | Engine load | shift-point analysis context |
| 0x0E | Timing advance | knock/heat proxy (nice-to-have) |
| 0x42 | Control module voltage | adapter/electrical health |
| 0x0B/0x10 | MAP / MAF | engine-load detail (nice-to-have) |

**One-shot per session:** VIN (0902), DTC/MIL status (0101), supported-PID bitmap.

**Derived from OBD (the differentiators):** current gear (speed/RPM vs. ND2 ratio table), shift events, rev-match blip quality, clutch-in inference (RPM–speed decoupling), time-in-gear / shift-point stats.

**Explicitly NOT available (set expectations):** brake pressure/position, steering angle, individual wheel speeds, clutch switch, lateral dynamics — all covered by phone IMU/GPS instead. This is why sensor fusion, not OBD, carries braking analysis.
