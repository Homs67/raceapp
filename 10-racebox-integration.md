# 10 — RaceBox Integration

Support for **RaceBox Mini, Mini S, and Micro** as a high-rate motion/position
source, plus a debug view to verify every signal against real hardware.

Protocol source: official *RaceBox BLE Protocol Documentation, Revision 9*
(published 4 Aug 2026), obtained from racebox.pro. All offsets, scales, and
example packets below are transcribed from that document.

---

## 1. What a RaceBox actually gives us

A RaceBox is **not** another car-data source — it does not touch the CAN bus or
OBD-II. It is a **better phone**: a u-blox GNSS receiver plus an accelerometer
and gyroscope, rigidly mounted to the car, fused into one 25 Hz message.

| Capability | Phone (today) | RaceBox | Veepeak/CAN (today) |
|---|---|---|---|
| Position / speed | 1 Hz, ~2 s doppler lag | **25 Hz**, GNSS-grade | — |
| Speed accuracy estimate | coarse | per-sample mm/s | — |
| Accel / gyro | 100 Hz, phone mount, handled | **25 Hz, car-rigid mount** | — |
| Satellites / PDOP / fix quality | not exposed | **yes** | — |
| Engine data (RPM, pedal, coolant…) | — | — | yes |
| Steering / brake | — | — | yes (CAN) |

So the three sources are complementary, and the compelling setup is
**RaceBox + Veepeak together**: RaceBox owns motion, Veepeak owns the engine.
That requires two simultaneous BLE links (see §3).

Secondary win, Mini S / Micro only: **standalone recording** — the device logs
to internal memory with no phone connected, and we can download it later (§7).

### Device differences

| | Mini | Mini S | Micro |
|---|---|---|---|
| Power | internal battery | internal battery | **12 V from OBD port only — no battery** |
| Byte 67 of data msg | battery % + charging bit | same | **input voltage ×10** (0x79 = 12.1 V) |
| Standalone recording | ✗ | ✓ | ✓ |
| Memory | — | 196 608 records (~16.5 MB) | same |
| NMEA output, GNSS config, 20 Hz | fw ≥ 3.3 | fw ≥ 3.3 | fw ≥ 3.3 |
| Start/stop button, persists config | ✗ | ✗ | ✓ |

> **Field note (2026-09-10):** a full BLE scan from the Mac found 84 devices and
> no RaceBox. The Micro has no internal battery — it cannot advertise on a desk.
> Live verification needs it plugged into the car's OBD port (or a 12 V bench
> supply / OBD breakout cable). It also will not advertise while connected to
> the RaceBox app on the phone.

---

## 2. Protocol summary (verified against Revision 9)

**Discovery.** Name begins `RaceBox Mini `, `RaceBox Mini S `, or
`RaceBox Micro ` + a 10-digit serial.

**Services.**

| Purpose | UUID |
|---|---|
| Device Info | `0000180A-…` — Model `2A24`, Serial `2A25`, FW `2A26`, HW `2A27`, Mfr `2A29` |
| UART service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX (we write) | `6E400002-…` |
| TX (we subscribe) | `6E400003-…` |

Nordic UART — the same shape as our ELM327 transport. Firmware ≥ 3.3 also
exposes NMEA on `00001101/1102/1103`; **do not use both** (the doc warns of
heavy packet loss). We use the RaceBox binary protocol only.

**Framing** — u-blox UBX:

```
B5 62 | class id | length (u16 LE) | payload | CK_A CK_B
```

Checksum is Fletcher-8 over class…payload:
`CK_A += byte; CK_B += CK_A` for every byte from offset 2 to len−3.

Little-endian, integers only (all reals are pre-scaled). Payload ≤ 504 bytes.

**Critical:** a BLE notification may contain a partial packet, one packet, or
several. A byte FIFO with resync-on-`B5 62` and checksum validation is
mandatory — same discipline as our ELM line buffer.

**Live Data Message — class `0xFF`, ID `0x01`, 80-byte payload, up to 25 Hz.**
Enabled automatically on subscribe; no command needed.

| Off | Type | Field | Scale → unit |
|---|---|---|---|
| 0 | u32 | iTOW | ms into GPS week |
| 4–10 | u16+5×u8 | Year, Month, Day, Hour, Min, Sec | UTC (month from 1) |
| 11 | bits | Validity flags | b0 date, b1 time, b2 fully resolved |
| 12 | u32 | Time accuracy | ns |
| 16 | i32 | Nanoseconds | signed, may be negative |
| 20 | u8 | Fix status | 0 none, 2 = 2D, 3 = 3D |
| 21 | bits | Fix flags | **b0 = valid fix**, b5 valid heading |
| 22 | bits | Date/time flags | b5/6/7 confirmations |
| 23 | u8 | Satellites used | count |
| 24 | i32 | Longitude | ÷1e7 → ° |
| 28 | i32 | Latitude | ÷1e7 → ° |
| 32 | i32 | WGS altitude | mm |
| 36 | i32 | MSL altitude | mm |
| 40 | u32 | Horizontal accuracy | mm |
| 44 | u32 | Vertical accuracy | mm |
| 48 | i32 | Speed | mm/s |
| 52 | i32 | Heading | ÷1e5 → ° |
| 56 | u32 | Speed accuracy | mm/s |
| 60 | u32 | Heading accuracy | ÷1e5 → ° |
| 64 | u16 | PDOP | ÷100 |
| 66 | bits | Lat/Lon flags | b0 = coordinates INVALID |
| 67 | u8 | Battery / voltage | Mini: b7 charging, b0–6 = %; **Micro: volts ×10** |
| 68/70/72 | i16 | G-force X / Y / Z | ÷1000 → g; X front/back, Y right/left, Z up/down |
| 74/76/78 | i16 | Rotation X / Y / Z | ÷100 → °/s; X roll, Y pitch, Z yaw |

Good fix = `fixStatus == 3 && (fixFlags & 1) != 0`.

**Other messages** (all class `0xFF`): ACK `0x02` / NACK `0x03` (payload = the
2 bytes being answered) · History data `0x21` (identical 80-byte payload) ·
Recording status `0x22` · Download `0x23` · Erase `0x24` · Recording config
`0x25` · Recording state change `0x26` · GNSS config `0x27` · Unlock memory
`0x30`.

The doc ships **worked example packets with byte-level decodings** for the data
message, recording status, recording config, state change, erase, unlock, and
ACK. These become our golden-vector unit tests (§4, Phase 0) — we can build and
verify the entire decode layer with zero hardware.

---

## 3. Architecture

### 3.1 Two BLE links at once

Today `ConnectionController` owns exactly one `CoreBluetoothTransport` (one
`CBCentralManager`, restore ID `com.raceapp.obd-central`). RaceBox needs a
second, concurrent link.

iOS allows multiple `CBCentralManager`s — the bug we fixed in `79d8f71` was
*duplicate restore identifiers*, not multiple managers. `CoreBluetoothTransport`
already defends against that with `claimRestoreIdentifier()`.

**Change:** give `CoreBluetoothTransport` an injected configuration instead of
hardcoded constants:

```swift
public struct BleDeviceProfile: Sendable {
    let restoreIdentifier: String   // unique per manager
    let advertisedNamePrefix: String?
    let serviceUUID: CBUUID
    let writeCharacteristic: CBUUID
    let notifyCharacteristic: CBUUID
}
```

`.veepeak` (FFF0/FFF2/FFF1, restore `…obd-central`) and `.raceBox`
(6E400001/2/3, restore `…racebox-central`). Everything else — the 12 s connect
timeout, the broadcast `incoming` stream, `isLinkReady`, reconnect, the restore
claim — is reused unchanged. This is the single highest-leverage piece of reuse
in the whole plan: the BLE hardening we already paid for applies to RaceBox for
free.

### 3.2 Package layout

```
Packages/BleKit/        ← extracted: CoreBluetoothTransport, ObdTransport
                          protocol, ReplayTransport, BleDeviceProfile
Packages/ObdKit/        ← depends on BleKit (ELM327/PID/CAN, unchanged)
Packages/RaceBoxKit/    ← new: framing, decode, session, commands
Packages/SessionKit/    ← depends on ObdKit + RaceBoxKit for channel ids
```

Extracting `BleKit` is mechanical (move two files, fix imports) and avoids
`RaceBoxKit` depending on `ObdKit` for no reason. If we want to defer it,
`RaceBoxKit` can import `ObdKit` temporarily — but do the extraction; it is
cheap now and annoying later.

### 3.3 RaceBoxKit contents

- `RaceBoxPacket` — framing + Fletcher checksum + **streaming parser** over a
  byte FIFO (resync on `B5 62`, length-aware, checksum-validated, counts
  malformed/dropped frames for the debug view).
- `RaceBoxDataMessage` — the 80-byte decode, typed and unit-converted.
- `RaceBoxModel` — `.mini / .miniS / .micro` from the Model characteristic, plus
  `firmware: (major, minor)` → capability flags (`supportsStandaloneRecording`,
  `supportsGnssConfig`, `supportsNmea`, `supports20Hz`).
- `RaceBoxCommand` — builders for `0x22/0x23/0x24/0x25/0x27/0x30` and
  ACK/NACK correlation.
- `RaceBoxSession` — actor mirroring `Elm327Session`: owns the transport, one
  reader task, a serial command lock with ACK/NACK waiting, `shutdown()`, and
  an `AsyncStream<RaceBoxDataMessage>` of live samples. (Reuse the serial-lock
  pattern from `Elm327Session` — actor reentrancy bit us before.)
- `RaceBoxSimulator` — synthesizes 25 Hz packets from the existing
  `TrackDriveSimulator` so demo mode and simulator screenshots work with no
  hardware.

---

## 4. Channel mapping into SessionKit

RaceBox replaces *phone position* and *car-frame G*, not the raw phone IMU.
No channel means two different things depending on hardware:

| RaceBox field | Channel | Notes |
|---|---|---|
| Latitude / Longitude | `gps.lat` / `gps.lon` | canonical — 25 Hz instead of 1 Hz |
| Speed (mm/s) | `gps.speed` | ÷1000 → m/s |
| Heading | `gps.course` | |
| MSL altitude | `gps.altitude` | ÷1000 → m |
| H/V/speed accuracy | `gps.hAcc` / `gps.vAcc` / `gps.speedAcc` | ÷1000 → m |
| UTC timestamp | `gps.wallTime` | epoch seconds |
| G-force X / Y | `car.longG` / `car.latG` | via `CarFrameCalibrator` (see below) |
| G-force X/Y/Z raw | `rb.gx` / `rb.gy` / `rb.gz` | raw device axes, for reprocessing |
| Rotation X/Y/Z | `rb.rotRoll` / `rb.rotPitch` / `rb.rotYaw` | ÷100 → °/s |
| Satellites | `rb.sats` | new capability |
| PDOP | `rb.pdop` | new capability |
| Fix status | `rb.fixStatus` | new capability |
| Battery % or voltage | `rb.battery` / `rb.voltage` | model-dependent |

Phone `imu.*` keeps recording raw device-frame motion regardless — it is a
different rigid body and must never be mixed with RaceBox axes.

`SessionManifest` gains `motionSource: "phone" | "racebox"` plus the device
model/serial/firmware, so every export says where `gps.*` came from.

**Calibration still applies.** The Micro plugs into the OBD port at whatever
angle the port sits, so we cannot assume X = forward. Feed RaceBox G through the
existing `CarFrameCalibrator` (gravity leveling + first-acceleration alignment)
exactly as we do phone IMU — it is simply a much better input: rigid mount, no
handling noise, already 25 Hz.

**Testable prediction:** `GForceValidator` correlates `car.longG` against
d(`gps.speed`)/dt. With a RaceBox both sides come from the *same* sensor fusion,
so the ~2 s GPS doppler lag we fought disappears. Expect **r ≈ 0.95+ at ~0 s
lag** versus today's r ≈ 0.90 at 1.5 s. If the lag search does not collapse to
zero, something is wrong with our time base — a free end-to-end correctness
check.

### Downstream wins, no extra work

`LapTimer`, `DragMeter`, `HighlightsAccumulator`, distance integration, the
track map, session graphs, and video review all read `gps.*` / `car.*`. They get
25 Hz data with no code change. Lap timing gate-crossing precision improves from
~±14 m at 50 mph (1 Hz) to ~±0.6 m (25 Hz) — that is the difference between
"lap timer" and *lap timer*.

---

## 5. Debug view (explicitly requested)

`RaceBoxDebugView`, reached from **Settings → Experimental**, alongside the CAN
Monitor and following the same shape (it is the pattern that worked for the
Veepeak spike, including the shareable log).

**Connection section** — scan/connect/disconnect, RSSI, and Device Info read
back live: Model, Serial, Firmware, Hardware, Manufacturer, plus the derived
capability flags.

**Live signals table** — every decoded field, each with its value, unit, and raw
integer, so a wrong scale is visible instantly:

- Fix: status, valid-fix bit, satellites, PDOP, h/v accuracy
- Time: UTC stamp, iTOW, validity flags, phone-clock delta
- Position: lat, lon, WGS alt, MSL alt
- Motion: speed (mm/s and mph/kph), heading, speed/heading accuracy
- G-force X/Y/Z with a live bar per axis
- Rotation roll/pitch/yaw with a live bar per axis
- Power: battery % + charging (Mini/Mini S) or input voltage (Micro)

**Link health** — measured packet rate (Hz), total packets, checksum failures,
resyncs, largest notification seen, and MTU. This is how we prove reassembly is
correct rather than assuming it.

**Standalone recording** (Mini S / Micro) — status, memory %, stored/total
records, security state; buttons for start/stop with the recommended filter
config, download (with progress), erase (double-confirmed), and unlock.

**Raw log + Share** — timestamped hex of every packet, shareable as a `.txt`,
exactly like the CAN monitor log. That is what lets us debug offline from a
drive, which is how we caught the fake-speed CAN signal.

A **self-test** button runs assertions and shows pass/fail per signal: packets
arriving ≥ 20 Hz, zero checksum errors over 10 s, UTC within 2 s of phone clock,
|G| ≈ 1.0 g at rest, rotation ≈ 0 °/s at rest, lat/lon inside a sane box,
accuracy < 10 m, voltage 11–15 V on the Micro. This turns "does it work?" into
one screenshot.

---

## 6. Settings / UX for two devices

Settings gains a **Devices** section with one card per device type — OBD adapter
(Veepeak) and RaceBox — each showing its own connection state and a
connect/forget action, replacing the implicit single-adapter model. Recording
uses whatever is connected; nothing is required.

Motion source resolution, in order: RaceBox with a valid fix → phone GPS. A
single line on the Record screen states which is live ("RaceBox · 25 Hz ·
11 sats"), because silently swapping the meaning of the speed readout would be
exactly the kind of dishonesty the rest of the app avoids.

---

## 7. Standalone recording & history import (Mini S / Micro)

The device records with no phone present, which is genuinely useful (no phone
battery drain, no app open, start/stop button on the Micro).

- **Status** `0xFF 0x22` → recording flag, memory %, stored/total records,
  security bits.
- **Configure** `0xFF 0x25` → enable, data rate (0 = 25 Hz, 1 = 10, 2 = 5,
  3 = 1, 4 = 20), filter flags, stationary threshold + interval, no-fix
  interval, auto-shutdown interval. Doc's recommended setup: all filters on,
  5 kph for 30 s, no-fix 30 s, auto-shutdown 5 min — **but disable the
  stationary filter when we care about standing starts** (drag runs).
- **Download** `0xFF 0x23` → device replies with the expected record count, then
  streams `0xFF 0x21` history messages plus `0xFF 0x26` state-change markers,
  ending with an ACK. Live data is suspended during download. Up to 16.5 MB at
  roughly 60 KB/s — several minutes; needs progress UI and cancel.
- **Erase** `0xFF 0x24` → progress notifications 0–100 %, cancellable.
- **Unlock** `0xFF 0x30` → 4-byte code; lock state resets on every connection,
  so check status and unlock on connect.

**Import:** `0xFF 0x26` state-change markers delimit separate drives in the
dump, so one download can split into several sessions. Each becomes a normal
session directory via `SessionRecorder`-equivalent ingestion, marked
`motionSource: racebox`, `phoneOnly: false`, with no OBD channels. Everything
downstream — graphs, export, video review — then works on them unchanged.

---

## 8. Phasing

| Phase | Work | Hardware needed |
|---|---|---|
| **0** | `BleKit` extraction · `RaceBoxKit` framing/decode/commands · golden-vector tests from the doc's example packets · `RaceBoxSimulator` | **none** |
| **1** | `BleDeviceProfile` in the transport · `RaceBoxSession` · **debug view** + self-test | Micro on 12 V |
| **2** | Channel mapping · `motionSource` in the manifest · calibrator + validator on RaceBox G · Devices UI · export/graph updates | Micro in car |
| **3** | Standalone recording control · history download + session import | Micro in car |
| **4** | GNSS config (dynamic model 4 automotive; 8 above 300 kph), AssistNow aiding for faster first fix, NMEA fallback if ever needed | Micro in car |

Phase 0 is substantial and needs no device — the doc's worked examples make the
decoder fully testable offline. Phase 1 ends at the debug view, which is the
instrument we use to validate everything after it.

---

## 9. Risks and cautions

- **Micro power.** No battery; 12 V from the OBD port. Bench testing needs an
  OBD breakout or 12 V supply. It also stops advertising while connected to
  another app — same "adapter won't show up" trap as the Veepeak.
- **Packet reassembly.** The doc is explicit that notifications split and merge
  packets. The FIFO + checksum path is the single most likely source of subtle
  corruption; the debug view's checksum-error counter exists to catch it.
- **Never run NMEA and the binary protocol together** — documented heavy packet
  loss.
- **Configuration writes can brick the device** and void warranty (the doc says
  so plainly). GNSS config is read-only by default; any write sits behind an
  explicit confirm. We never touch port/protocol configuration.
- **Two BLE links** raise connection-interval contention; if the RaceBox drops
  packets while the Veepeak polls hard, prefer the RaceBox (motion data is the
  higher-rate, less recoverable stream).
- **Restore identifiers must stay unique.** One per profile, enforced by the
  existing claim guard. This is the bug that cost us a full debugging session.
- Data volume: 25 Hz × ~15 channels is well within the append-only writer's
  budget (the phone IMU already writes 100 Hz × 7).

---

## 10. Verification tooling already built

`~/Applications/RaceBoxProbe.app` — a signed macOS CLI/bundle that scans for a
RaceBox, connects, reads Device Info, subscribes to the UART TX characteristic,
reassembles and checksum-validates packets, decodes the full 80-byte message,
measures the packet rate, and round-trips a recording-status command to prove
the write path. Source: `scratchpad/racebox-probe.swift`.

Bluetooth permission is granted and it runs clean; it found 84 BLE devices and
no RaceBox, which is how we learned the Micro was unpowered. **Plug the Micro
into the car and run it** — it is the fastest way to confirm every offset in §2
against real hardware before any app code is written:

```bash
open ~/Applications/RaceBoxProbe.app --args 20
```

Output lands in `scratchpad/probe-live.txt`.
