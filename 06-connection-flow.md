# OBD2 Connection Flow (v0.1)

UX + technical flow for connecting the Veepeak OBDCheck BLE+ to our app. Companion to 03-obd2-integration.md (protocol details) and 05-design-brief.md (v1 scope). Benchmark: Car Scanner's iOS setup — it works, but demands three decisions from the user (connection type, device, connection profile) and a red-ink warning about iOS Settings. Ours asks **zero decisions on the happy path**.

---

## 1. Principles

1. **Zero configuration.** BLE is the only transport, `VEEPEAK` is auto-detected, protocol is auto-negotiated. No "connection type," no "profile" — the app knows.
2. **Two-stage truth.** "Connected" is ambiguous: adapter link (BLE+ELM) and car link (ECU) are separate and fail separately. Show both, like Car Scanner's `ELM: Connected / ECU: Connected` footer — its one genuinely good pattern.
3. **Preempt the Settings trap.** Users trained by every other BT device will open iOS Settings and tap VEEPEAK, which errors and *hides the device until the adapter power-cycles* (per manual). Our onboarding says up front: "No pairing needed — don't open Bluetooth Settings." If we can't find the adapter, the recovery checklist includes exactly this failure.
4. **Connect once, never again.** After first setup, reconnection is automatic and invisible — open app, data appears.

## 2. First-time flow (onboarding)

```
[1] Plug in        [2] Searching…      [3] Found           [4] Linking            [5] Live
 illustration:      spinner +           "VEEPEAK" card       ELM ✓                  dashboard,
 OBD port under     "plug in, turn      auto-highlighted,    ECU ✓ (car: MX-5,      data moving
 dash, ignition     ignition on"        [Connect] CTA        VIN …367)              within ~5s
 on, blue light
```

**Step 1 — Prep screen.** One illustration: adapter in port (mention: usually under the dash, driver's side; remove cover if present), ignition ON (engine can be off), "look for the blue light." Below the fold: "No pairing needed — we connect directly. Don't add it in Bluetooth Settings."
- Behind the scenes: request Bluetooth permission here (`CBCentralManager` instantiation triggers the iOS prompt) — attached to a screen that explains *why*, so the permission ask has context.
- Gate states: Bluetooth off → inline "Turn on Bluetooth in Control Center" (no API to toggle it for the user). Permission denied → deep-link to app Settings.

**Step 2 — Scan.** Start scanning immediately while the prep screen is still up (the search runs during reading — most users never see a "searching" state). Filter advertisements by name `VEEPEAK`; show a live list anyway with a "Don't see your adapter?" expander that reveals *all* discovered peripherals (clone adapters advertise other names; this also future-proofs for OBDLink MX+ and RaceBox).

**Step 3 — Found.** VEEPEAK card slides in, auto-highlighted, single **Connect** button. (Auto-highlight + one tap, not fully automatic: if the paddock has three MX-5s with Veepeaks, the tap is the disambiguation. RSSI-sort the list so the closest is on top.)

**Step 4 — Linking, two visible stages.**
- *Stage A — Adapter* (`Connecting → DiscoveringGATT → InitializingELM` from 03 §2): connect peripheral, discover services, find the write+notify pair, run the AT init sequence. Success = `ATZ` answers `ELM327 v2.2`. Show: **Adapter ✓**.
- *Stage B — Car* (`ConnectingECU`): `ATSP0` (auto) + `0100`. On success: read VIN (`0902`), run supported-PID discovery (`0100/20/40/60`), pin the discovered protocol (`ATSP6` for the ND2 hereafter) and persist it with the car profile. Show: **Car ✓ — Mazda MX-5 (VIN …367)**. If VIN decodes to a known preset, attach it silently; else ask make/model once (v1 only needs it for the gear-ratio table).
- Persist: peripheral `identifier`, GATT characteristic UUIDs, protocol number, PID capability bitmap → `AdapterProfile` + `CarProfile`.

**Step 5 — Done.** Straight to the live dashboard, gauges moving. No summary screen — moving data *is* the confirmation.

## 3. Every-subsequent-launch flow (invisible)

- On launch (or foreground): `retrievePeripherals(withIdentifiers:)` → `connect()`. iOS connect requests **don't time out** — leave it pending; the moment the adapter powers up (car ignition), iOS completes the connection, we re-init ELM (init is idempotent, run it every time) and data flows.
- Status chip on the dashboard is the only UI: `Adapter —` / `Adapter ✓ Car —` / `● Live 12Hz`. Tap it for detail + manual controls (rescan, forget adapter).
- **`bluetooth-central` background mode + state restoration**: reconnect and resume logging even if the app was backgrounded/relaunched by iOS mid-session.
- **Waiting-for-ignition state:** most OBD ports are always powered, so BLE can connect while the car is off but Stage B fails (`UNABLE TO CONNECT`). Don't error — show "Waiting for ignition…" and retry `0100` every few seconds. Turning the key makes the app come alive by itself. This state doubles as the natural pre-drive experience: open app, get in, start car, gauges wake up.

## 4. Failure paths (each with one specific recovery, not a generic error)

| Symptom | Detected by | Message / recovery |
|---|---|---|
| Nothing found after ~15s | scan timer | Checklist, in evidence order: blue light on? (fuse/seating) → ignition on? → **another app connected?** (adapter accepts one link — "close Car Scanner/RaceChrono") → "did you pair it in Bluetooth Settings? Unplug the adapter for 10s, plug back in" |
| Found, but connect fails or drops instantly | CB error / immediate disconnect | Usually the Settings-pairing trap or a contested adapter → same last two recovery items |
| Adapter ✓ but no ELM response | init timeout | Power-cycle adapter; flag adapter as possibly counterfeit if `ATZ` returns garbage |
| ELM ✓, ECU ✗ | `UNABLE TO CONNECT`/`NO DATA` | "Waiting for ignition…" passive state (§3); if ignition *is* on → seat the adapter firmly, try another drive cycle |
| Connected, then drops mid-session | disconnect delegate | Silent auto-reconnect w/ backoff (0.5s→5s); chip shows reconnecting; gap marked in the recording, never an alert while driving |
| Data goes stale (connected but silent) | watchdog: no fast-loop sample for >2s | Soft ELM re-init in place; escalate to full reconnect if repeated |

## 5. State machine (extends 03 §2)

```
Idle → NeedsPermission → Scanning → Connecting → DiscoveringGATT
     → InitializingELM → ConnectingECU ⇄ WaitingForIgnition
     → Live(Polling)
        └─ drop → Reconnecting (backoff) → InitializingELM …
```

Every state maps 1:1 to a UI string on the status chip. The state machine lives in `ObdKit` and is UI-agnostic — the onboarding screens and the dashboard chip render the same state stream.

## 6. What we deliberately do differently from Car Scanner (per the screenshot)

| Car Scanner asks | We do instead |
|---|---|
| Choose connection type (WiFi / BLE / MFi) | BLE only — no question |
| Pick device from a raw BT list | Auto-detect `VEEPEAK`, RSSI-sorted, one tap |
| Choose a "connection profile" (Ford OBD-II/EOBD…) | Auto protocol detect once, pinned per car; VIN identifies the car |
| Red-ink manual warning about Settings pairing | The trap is preempted in onboarding copy and diagnosed in the not-found checklist |
| Separate Connect button on main page | Auto-reconnect on launch; connection is a status, not a task |

## 7. Build order

1. `ObdKit` state machine + replay transport (unit-testable, no hardware) — states/transitions above.
2. Discovery spike screen (03 §6) exercises `Scanning → Live` on the real ND2, logs GATT tree + transcripts, fills in the ⚠ unknowns.
3. Onboarding screens (steps 1–5) — thin views over the state stream.
4. Failure-path polish using real transcripts from the spike as replay fixtures (each row in §4 becomes a replayable test).
