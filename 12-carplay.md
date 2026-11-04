# 12 — CarPlay

Feasibility and effort for putting raceApp on the car's screen, RaceBox (and
OBD) data included. Written 28 Oct 2026.

**Short version:** the app can get on CarPlay for roughly **8–12 working days**
of implementation, but **not as a live dashboard**. Apple forbids custom UI
outside navigation apps and caps non-navigation refresh at **once every 10
seconds** — so a gauge screen, a running lap timer, or a live delta bar are all
off the table. What fits is a *driving-task* app: a template screen that shows
session status and the lap list, starts and stops recording, and updates
per-lap. The genuinely "live" channel in the car is **audio**, which needs no
entitlement at all and is ~1–2 days of work.

---

## 1. What Apple actually allows

From the current *CarPlay Developer Guide* (Oct 2026 revision, Apple):

| Rule | Consequence for us |
|---|---|
| Custom UI is impossible except for navigation apps' own map canvas | No gauges, no `DashboardGridView` on the car screen, no custom timer |
| Display data refreshes **≤ once per 10 s** (driving task) | Lap times: fine. RPM / speed / G / delta: not allowed |
| Template depth: **2** on iOS ≤ 26.3, **3** on iOS ≥ 26.4 (root counts) | Root + one detail level. Design for 2 |
| One entitlement category per app (except EV charging + fuelling) | `driving-task` is ours; choosing it rules out `navigation` forever |
| No setup / sign-in / unrelated tasks in the CarPlay UI | Device pairing, settings, garage stay phone-only |
| Entitlement granted by Apple on request, under an addendum | Blocking, and refusable — see §5 |

**Precedent.** Harry's LapTimer shipped CarPlay in 25.0.1 (May 2025) and is the
closest thing to this app on the store. Its developer wrote on the LapTimer
forum that the 10-second rule means **there will be no Timer View replacement
on CarPlay**, that a custom layout like the Timer View "is not possible
either", and to "not expect more fancy displays" — their CarPlay screen is a
list of recent laps with the last lap and last completed sector highlighted.
That is the ceiling, and it was reached by someone who got the entitlement.

So: CarPlay is a **convenience surface** (glance at last lap, start/stop
without touching the phone), not a second dashboard. The phone on a mount stays
the dashboard.

---

## 2. What the codebase already gives us

The architecture happens to be nearly ideal for this. CarPlay is a second
*scene* in the same app target — no new target, no duplicated logic.

- **`TelemetryBus`** — thread-safe latest-value snapshot, already feeding three
  consumers. A CarPlay presenter is a fourth reader; nothing changes upstream.
- **`DashboardLiveFeed.tick(model:now:date:metric:)`** → **`LiveSnapshot`** —
  one pure-ish function that already assembles everything a screen could want
  (lap state, sector deltas, RaceBox satellites/power, OBD link flags,
  recording state). Call it at 0.1 Hz instead of 10 Hz and the whole CarPlay
  data layer is done.
- **`AppModel`** — single composition root (`bus`, `connection`, `raceBox`,
  `recording`, `metrics`). Start/stop is already `startRecording(metricUnits:)`
  / `stopRecording()`.
- **Background modes** `bluetooth-central` + `location` are already declared,
  so BLE and recording survive with no phone UI on screen.
- **RaceBox is source-transparent**: it publishes into `gps.*` on the same bus,
  so a CarPlay screen needs no RaceBox-specific code — it benefits from the
  25 Hz link automatically.

### What has to change in the app itself

1. **`AppModel` must be shared, not view-owned.** Today it is
   `@State private var model = AppModel()` inside `raceAppApp`. A CarPlay scene
   delegate cannot reach that. Needs a single shared instance both scenes read.
2. **Launch bootstrap must move off the view.** `model.onLaunch()` runs from
   `ContentView.task`. An app launched *into CarPlay only* never builds
   `ContentView`, so sensors, OBD connect and RaceBox auto-connect would never
   start — and the recovery path (`recording.recoverAtLaunch()`) never runs.
   This is exactly the class of bug Harry's shipped and then fixed ("crash when
   the app launches with CarPlay connected").
3. **Explicit scene manifest.** The target currently uses
   `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`. That has to be
   turned off and a real `UIApplicationSceneManifest` written into
   `Config/Info.plist` with both the window-scene role and
   `CPTemplateApplicationSceneSessionRoleApplication` →
   `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`.
4. **Entitlement** `com.apple.developer.carplay-driving-task` added to
   `raceApp/raceApp.entitlements` — only once Apple grants it.

---

## 3. Proposed scope (v1)

**Root template** (`CPInformationTemplate`, refreshed every 10 s):

- Track / session line: track name, elapsed, laps done
- Last lap, best lap, delta of last lap vs best *(per-lap values, not live)*
- Links line: RaceBox sats + fix, OBD live/not
- Actions: **Start session** / **Stop session** (with a `CPAlertTemplate`
  confirmation on stop), **Laps**

**Depth 2** (`CPListTemplate`): recent laps, newest first, best lap marked —
appended as each lap closes, which is naturally far slower than 10 s.

**Guard rails:**

- If location permission is missing or no source is connected, the root shows a
  single row and an alert telling the driver to open the phone app. CarPlay must
  not be used for setup, so no pairing flow there.
- A 10-second throttle sits in the presenter, not in the templates, so there is
  one place to prove the rule is respected in App Review.

**Out of scope:** gauges, live delta, map, camera control, device pairing,
settings, session browsing/export.

---

## 4. The part that actually helps a driver: audio

No entitlement, no templates, no Apple review risk — the app already owns the
audio session when CarPlay (or plain Bluetooth) is connected.

- Spoken lap time + delta at each lap crossing ("1:34.4, half a second up")
- Optional sector call-outs, shift tone, a chime on session start/stop
- `AVSpeechSynthesizer` + `AVAudioSession` with ducking, settings toggle

~1–2 days, works in **every** car including ones without CarPlay, and delivers
the information the 10-second rule denies the screen. If only one of these two
tracks gets built, build this one.

---

## 5. Effort and schedule

| Phase | Work | Effort |
|---|---|---|
| 0 | Entitlement request: justification, mockups, category = driving task | 0.5 day + **Apple's wait** |
| 1 | Shared `AppModel`, bootstrap off the view, scene manifest, `CarPlaySceneDelegate`, root template on screen in the Simulator's CarPlay display | 1–1.5 days |
| 2 | Information root + lap list, start/stop + confirm alert, permission/no-source states, 10 s throttle, units | 2–3 days |
| 3 | Lifecycle matrix: CarPlay-only launch, connect/disconnect mid-session, phone foregrounds mid-session, phone locked, both BLE links up, dashboard ↔ CarPlay state sync | 2–3 days |
| 4 | Audio coach (§4) | 1–2 days |
| 5 | Test pass, one real-car session, App Review notes | 2–3 days |

**Implementation total ≈ 8–12 working days**, of which ~2–3 is the plumbing and
most of the rest is lifecycle and verification. Add one track/road day with the
car.

Useful detail: the **Simulator does not enforce entitlements**, and Xcode can
show a CarPlay display (I/O → External Displays → CarPlay). Phases 1–3 can be
built and demoed *before* Apple answers; only real head-unit testing and
shipping need the grant.

### Risks

1. **Entitlement refusal or silence.** Apple grants per-app under an addendum,
   with no published turnaround. Harry's got one, which is encouraging but not
   a guarantee. Everything in phases 1–3 is wasted if it is refused — so do
   phase 0 first and §4 in parallel.
2. **Category lock-in.** Taking `driving-task` forecloses `navigation` later.
3. **Review on the 10-second rule.** Any screen that looks like a live gauge
   invites rejection; keep the throttle explicit and documented.
4. **Expectation gap.** "CarPlay support" will read to users as "my dashboard
   on the car screen". Release notes should say what it is: lap list, status,
   start/stop. Worth deciding before marketing it.

---

## 6. Recommendation

1. **Build the audio coach now** (§4). Cheap, no gatekeeper, helps in any car.
2. **File the entitlement request in parallel** (§5 phase 0) — the clock is the
   long pole, not the code.
3. **Build phases 1–3 against the Simulator** once the request is in; ship when
   the grant lands.
4. Do **not** plan a CarPlay dashboard. It is not permitted, and the one
   comparable app on the store has publicly hit the same wall.

---

## 7. The other way onto the screen — and why it isn't ours

Kansei Link (kanseilink.com, $49 / $99) puts exactly the dashboard this
document says is impossible — speedo, RPM, gear, coolant, intake, lap timing,
a dyno — on an MX-5 ND's centre screen. It does it by **not involving Apple at
all**: it is not an iPhone app. It installs *onto the Mazda Connect head unit*
from a USB stick and replaces Mazda's own display.

How the pieces line up:

- **Target:** MX-5 ND1/ND2, Mazda Connect firmware **74.00.324 or 324A only** —
  "on any other firmware, the installer stops and changes nothing."
- **Install:** park, engine running, insert USB, wait. The same stick has a
  REMOVE option that restores the stock screen. A Mazda software update wipes it.
- **Vendor:** Braw Cyber Security Ltd, a Scottish security company.
- **The mechanism:** 74.00.324A is the exact build ZDI published multiple
  unpatched CMU vulnerabilities against in Nov 2024 — command injection via
  crafted filenames on a FAT32 USB stick, giving root code execution and
  persistence on the head unit. Pinning to one firmware, a security-company
  author, and a USB installer that reverts cleanly is that research turned into
  a product.
- **Data:** the CMU already sits on the vehicle CAN bus, so wheel speed, RPM,
  gear and temperatures are local reads. GPS comes from the head unit's own
  receiver. No phone, no OBD dongle, no BLE.
- **Precedent:** the community did this years earlier with CASDK (JS/CSS apps
  on the CMU, speedometer sample included) and MZD-AIO tweaks, before Mazda
  locked the unit down.

**Why raceApp can't copy it:** it's a different product. Per car model, per
firmware build, voids warranty, dies at the next dealer update, and is sold
outside the App Store because it could never be in it. Our app is one install
across every car, survives updates, and owns things the head unit cannot do —
25 Hz RaceBox motion, camera + video sync, iCloud, sessions on the phone.

**What it does tell us:** a screen in front of the driver showing live gauges
is clearly wanted enough to pay $49–$99 for, and a locked-down CarPlay can
never serve it. For us that demand is answered by the phone on a mount (today's
dashboard) plus audio in the car (§4) — not by CarPlay.

---

Sources: Apple, *CarPlay Developer Guide* (Oct 2026),
<https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf>;
Harry's LapTimer release notes, App Store id363556704; Harry's GPS Suite forum
thread 2687 (developer statements on the 10 s limit and custom layouts).
