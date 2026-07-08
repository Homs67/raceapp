# Build Plan — v1.0 (v0.1)

Step-by-step implementation plan for 07-requirements-v1.md. Ordering logic: **everything hardware-independent first** (testable at a desk), the **driveway spike as early as possible** (it resolves every remaining unknown), UI only after data flows, visual polish last (when the HTML design prototype lands).

---

## Phase 0 — Project setup *(half a day)*

1. Clean the Xcode template: remove `Item.swift`/SwiftData scaffolding, set iOS 17 target, add background modes (`bluetooth-central`, `location`), permission strings (Bluetooth, location, motion).
2. Create two local Swift packages, app target stays thin:
   - **`ObdKit`** — BLE transport, ELM327 session, PID decoding, connection state machine. Zero UI imports.
   - **`SessionKit`** — phone sensors, channel model, append-only recording, session store, export. Zero UI imports.
3. Storage decision (from 01 §5): **GRDB/SQLite** for session metadata + index; raw samples as append-only binary sidecar files per channel. Add GRDB dependency now.

**Exit:** empty 4-tab app builds and runs; both packages have a passing placeholder test.

## Phase 1 — ObdKit core, no hardware *(2–3 days)*

1. `ObdTransport` protocol + **`ReplayTransport`** (plays recorded/synthetic transcripts) — the testing backbone and later the demo mode (R5.4).
2. `Elm327Session`: command queue, tolerant line-accumulator parser (accumulate to `>` prompt), error states (`NO DATA`, `STOPPED`, `UNABLE TO CONNECT`…).
3. `PidDecoder`: pure hex→value functions for every PID in 03 §8, unit-tested (`410C1AF8` → 1726 rpm).
4. Connection state machine (06 §5): `Idle → … → Live(Polling)` incl. `WaitingForIgnition`, `Reconnecting`; exhaustive transition tests against replay scripts.
5. `PidPoller`: fast/slow loop scheduler emitting `(t, channel, value)`.
6. `CoreBluetoothTransport`: scan/filter `VEEPEAK`, GATT discovery (log full tree), write chunking, notify assembly.

**Exit:** full connect→poll cycle runs green against ReplayTransport; CB transport compiles and scans (untested against real adapter — that's Phase 2).

## Phase 2 — Discovery spike, real car *(1 day, needs the ND2 + adapter)*

Per 03 §6: debug screen → dump GATT tree → run init → stream RPM/speed/throttle → measure sequential vs. multi-PID Hz → run supported-PID discovery (oil temp? pedal position? multi-PID?) → log every raw byte both directions.

**Exit:** `obd-nd2-facts.md` written; real transcripts checked in as ReplayTransport fixtures; the ⚠ unknowns in 03/06 resolved; fast-loop strategy locked (multi-PID or sequential).

## Phase 3 — SessionKit: sensors + recording engine *(3–4 days)*

1. Channel model (01 §4.3): native timestamps per channel, GPS-time master clock, no resampling.
2. `SensorSuite`: CoreLocation (with per-fix accuracy), CoreMotion @ 100Hz, CMAltimeter, device battery/thermal.
3. **Append-only `ChannelWriter`** (R1.5): samples hit disk as they arrive; crash-recovery scan on launch → "recovered" sessions.
4. Session lifecycle: start/stop, phone-only mode (R1.4), **auto-stop rule** (OBD gone + stationary 5 min → save + notification, R1.6).
5. Background operation: recording survives lock/background/calls (R1.7); OBD gap marking on dropout (R1.8).
6. CSV (RaceChrono-compatible) + JSON sidecar export (R4.5), golden-file tested.

**Exit:** headless recording works end-to-end with ReplayTransport + real phone sensors on a desk; kill-test passes (acceptance #5); export opens in Excel.

## Phase 4 — App skeleton: tabs, connection flow, state plumbing *(2–3 days)*

1. 4-tab structure (07 §1); observable app-state layer bridging ObdKit/SessionKit streams to SwiftUI.
2. Connection tab: 5-step first-time flow + recovery checklist (06 §2/§4), status detail, forget-adapter, auto-reconnect on launch (R6.1), settings stubs (units, keep-awake, storage), privacy statement.
3. Status strip component (R2.3) shared by Record tab.
4. Demo mode button wired to ReplayTransport with a bundled fixture (R5.4).

**Exit:** on-device: first-time connect against the real adapter via the designed flow; relaunch auto-reconnects; demo mode drives fake data through the whole app.

## Phase 5 — Record tab + Health tab (the visual core) *(3–5 days)*

**⟵ The HTML design prototype slots in here.** Build order within the phase:
1. Functional-first pass with plain layout: all R2/R3 gauges rendering live values, stale/no-data states (R2.5), both orientations (R2.4).
2. Extract design parameters from the prototype (type scale, colors, gauge geometry, spacing, redline treatment, G-meter style) into a design-token layer.
3. Apply the design: landscape hero layout, portrait stack, health gauge grid, value-age indicators.
4. Start/Stop session button + recording state UX (R1.1–R1.3), keep-awake toggle.

**Exit:** the app looks like the prototype and runs live in the car; a real drive records while the dashboard displays.

## Phase 6 — Sessions tab *(2–3 days)*

List (duration/distance/geocoded location) → detail (highlights per R4.2, MapKit trace R4.3, note field, per-channel sample counts + gaps) → share-sheet export → swipe-to-delete + storage usage.

**Exit:** acceptance #3 and #4 pass (phone-only session lists and exports; CSV imports into RaceChrono).

## Phase 7 — Hardening + acceptance *(1 week of real use)*

1. Thermal/battery warnings (R6.3); polish reconnect edge cases found in real use.
2. Founder runs the acceptance suite (07 §9): week of daily driving, one Streets of Willow day, forgotten-stop test, kill-test, demo-mode review pass.
3. Fix what the week surfaces; tag v1.0.

---

## Sequencing notes

- **Phases 1 and 3 are desk-work** — most of the app is built and tested with ReplayTransport before the car is needed again after the 1-day spike.
- **Phase 2 is the only hard scheduling constraint** (needs the car); do it the first day the adapter and an hour in the driveway coincide. Everything in Phase 1 is written so the spike is just "run it and record."
- The HTML prototype is not blocking: Phase 5 step 1 is deliberately design-free, so UI work can start before the prototype arrives and re-skin when it does.
- Total rough estimate: **~3 weeks of build** + 1 week of real-use hardening.
