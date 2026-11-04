# Collapsed recorder — build plan

Designs: Figma board **06 · Collapsed recorder**, section H (`315:7275` in the Track-App file).
Three mocks: ① dashboard chrome, ② Live Activity, ③ in-app session preview bar.
Landscape is ④ `350:4182` — the chosen one: top row unchanged, controls as a bottom **overlay**
rather than layout, so the grid keeps its full height.

Today the recording dashboard is a `fullScreenCover` bound straight to `recording.isRecording`
(`raceApp/ContentView.swift:66`) with `.interactiveDismissDisabled()`, and the comment above it says
the only way out is STOP. That is the thing this work changes.

---

## Phase 0 — Pause in the data model — **done**

Decided: a paused-then-resumed session stays ONE session made of segments.

Landed:

- `SessionManifest` — `Status.paused`; `Segment { start, end? }` in the same monotonic-uptime basis
  as sample `t`; `segments: [Segment]?`; `recordedSeconds(asOf:)`, `isPaused`, `isLive`.
  Manifests from before this change carry no segments and fall back to their finalized duration.
- `SessionRecorder` — `pause(at:)` / `resume(at:)` / `isPaused`. Pause closes the open segment and
  any open OBD gap, flushes and saves; resume opens a new segment and **resets every continuity
  tracker** (`lastSampleT`, `lastSensorSampleT`, `lastRaceBoxSampleT`, `openObdGapStart`,
  `HighlightsAccumulator.noteDiscontinuity()`, `AutoStopMonitor.noteResumed(at:)`). Without those
  resets each pause invents a sensor dropout, an OBD gap and a slug of phantom distance.
  `ingest` drops samples while paused; `shouldAutoStop` stands down while paused.
- `HighlightsAccumulator.finalize` takes `recordedSeconds` so `durationSeconds` excludes paused time.
- `SessionStore.recoverInterruptedSessions` now claims `isLive` (recording **or** paused) sessions —
  a session paused when the app was killed would otherwise never be closed by anything.
- `RecordingCoordinator` — `isPaused`, `pause()`, `resume()`, `elapsed(asOf:)` built from banked
  segments so the clock freezes; the quiet-sample warning is suppressed while paused.
  Note `samplesMayBePaused` on this type is the pre-existing "iOS may have suspended capture"
  warning and is unrelated.
- `DashboardLiveFeed` feeds `live.elapsed` from `recording.elapsed(asOf:)` instead of wall clock.
- Tests: 9 new in SessionKit (segment duration, dropped samples while paused, no phantom distance,
  no sensor gap across a pause, auto-stop stand-down, stop-while-paused, legacy fallback,
  open-segment maths, paused-session recovery). Suite green at 150 XCTest + 12 swift-testing.

- `Packages/SessionKit` — `SessionManifest` gains `segments: [Segment]` (`start`/`end` UTC);
  `durationSeconds` becomes the sum of segment durations rather than `end - start`.
  `Status` gains `.paused`.
- `SessionRecorder` — `pause()` / `resume()`; close the open segment on pause, open a new one on
  resume, keep the file handles and channel writers alive so resume is cheap.
- `raceApp/Model/RecordingCoordinator.swift` — `isPaused`, `pause()`, `resume()`; elapsed derives
  from recorded segments so the clock freezes while paused.
  **Name collision to avoid:** `samplesMayBePaused` already exists on this type and means
  "the feed has gone quiet" (a warning), not "the user pressed pause". Do not reuse it.
- Ingest: drop samples while paused rather than stopping the stream — the OBD/RaceBox links stay up
  so resume is instant.
- Tests: extend `Packages/SessionKit/Tests/SessionKitTests/SessionRecorderTests.swift` for segment
  math — pause/resume/pause, duration excludes paused time, a session paused at stop still finalises.
  Run with `cd Packages/SessionKit && swift test`.

## Phase 1 — Dashboard chrome (mock ①, ④) — **done**

- `RecordingToolbar.swift` now holds two views instead of one. `RecordingTopBar` is permanent —
  elapsed pill, page dots, collapse — and `RecordingControlBar` is the only thing
  `ToolbarVisibility` governs.
- **Visibility is inverted from the old behaviour:** controls start on screen and a tap puts them
  away, and they no longer auto-hide after 4 s. A bar that vanishes on its own is one you hunt for
  at the end of a session.
- The `edge` parameter is gone: both orientations put controls along the bottom, `compact: true`
  in landscape (48 pt controls, 150 pt scrim instead of 56/190).
- Page indicator changed from 18×12 pills to 7 pt dots, and stop went from black-on-red "STOP" in
  Sofia to white-on-red "Stop" in SF Pro semibold, both per the mock.
- `RecordingIslandDot` is no longer drawn — the permanent top bar carries a dot and the clock a few
  points away, so the two collided. The type is left defined; its island geometry is worth keeping.
- The collapse chevron takes an **optional** `onCollapse`. It is `nil` until Phase 2, so the button
  is absent rather than inert — a chevron that dismisses the dashboard with nothing to come back
  through would strand a live session.
- **The grid is inset below the top bar** (`RecordingTopBar.height(safeTop:)` folded into
  `gridSafe.top` while recording). The old toolbar could overlap widgets because it was hidden by
  default; a permanent bar cannot. The control bar stays a pure overlay, since it can be tapped away.
- The top bar also respects `gridInsets`' leading/trailing so the pill and chevron clear the
  Dynamic Island in landscape, where it sits on a long edge.
- The pager is centred in a `ZStack` against the full width, not between the pill and the chevron —
  those are different widths, so an `HStack` pushed the dots off-centre.
- The elapsed pill has a paused look (grey bars, dimmed clock, neutral capsule) so it stops claiming
  to be recording. The full paused-dashboard treatment from section G (scrim + PAUSED panel) is
  **not** built — that is still a separate piece.
- `GridGeometry` used to hard-code `top = 0` in landscape, since there is no sensor housing up
  there. It now honours `safe.top` in both orientations; callers that do not need it still pass 0,
  and the recording dashboard passes its top-bar height. Without this the landscape grid ran
  straight under the bar.

Verified on the simulator: portrait and landscape both inset correctly, the pager sits on the
screen centre, pause swaps the pill to its paused look and the button to play, and the segment
closes at the right instant. Stop and resume from these controls were not exercised end to end —
the simulator kept shutting itself down mid-run.

### Original plan



`raceApp/Dashboard/Views/RecordingToolbar.swift` already has most of the behaviour: `ToolbarVisibility`
does tap-to-toggle with a 4 s auto-hide and an `arm()` guard for the spurious tap as the cover lands.
Keep that class; split the view in two.

- **`RecordingTopBar`** — always visible, never auto-hides: elapsed pill (left), page dots (centre),
  collapse chevron (right). Same order in both orientations.
- **`RecordingControlBar`** — the only thing `ToolbarVisibility` governs now: pause + red stop over a
  gradient scrim, pinned to the bottom edge in **both** orientations (56 pt controls portrait, 48 pt
  landscape). It is an overlay, not layout, so landscape loses no grid height.
- Delete the `edge` parameter — landscape no longer puts controls along the top. The existing page
  pills move into the top bar; `stopButton` becomes red-filled with a white square + "Stop".
- `DashboardPagerView.swift:151–172` — wire both bars; keep `RecordingIslandDot` as is.
- Landscape is already handled through `verticalSizeClass == .compact` and
  `GridGeometry(landscape:)`; this phase only needs the new chrome to respect it.

## Phase 2 — Collapse + in-app session preview bar (mock ③) — **done**

- `AppModel.isDashboardPresented` splits "a session is recording" from "the dashboard is covering
  the app". Set true when a session starts, false by the chevron and by `onRecordingDidStop`.
  `ContentView`'s cover binds to it instead of `recording.isRecording`.
- New `raceApp/Views/SessionPreviewBar.swift`: indicator, elapsed, divider, name, pause (white),
  stop (grey), open. Tapping anywhere that is not a button opens the dashboard.
- **The inset is applied per tab, not to the `TabView`.** A `safeAreaInset(edge: .bottom)` on the
  TabView lands *below* the tab bar, and the bar's height differs between OS versions so no
  hard-coded offset is right. Insetting each tab's content also stops lists scrolling under it.
- Title falls back track name → geocoded start location → "Session", so it is never blank.
- Elapsed ticks from a `TimelineView` and uses `m:ss` under an hour, `HH:MM:SS` over.
- The bar sits on an `.ultraThinMaterial` under its tint. A flat translucent fill let session-card
  text read straight through it as the list scrolled past.

Verified on the simulator: collapse leaves the session running, the bar appears above the tab bar
and survives switching tabs, open returns to the dashboard with the clock carried across, and stop
from the bar finalizes the session — `status: complete`, one closed segment, duration equal to the
segment length. Pause from the bar (as opposed to from the dashboard) was not exercised.

### Original plan



- `ContentView.swift:66` — the cover's binding stops being `recording.isRecording` and becomes a
  separate `model.isDashboardPresented`, so collapsing dismisses the cover while recording continues.
  Drop `.interactiveDismissDisabled()` or keep it and rely on the chevron; update the stale comment.
- New `raceApp/Views/SessionPreviewBar.swift` — dot, elapsed, divider, session name, pause,
  grey stop, open. Truncates the name; ~150 pt available for it.
- **Deployment target is iOS 17.0**, so `tabViewBottomAccessory` (iOS 26) is not available — the bar
  is hand-rolled as a `safeAreaInset(edge: .bottom)` on the `TabView` so the lists inset correctly
  instead of scrolling under it by accident. It must show on all three tabs.
- Transition: matched geometry between the dashboard's elapsed pill and the bar, ~350 ms spring,
  light haptic. Reverse on open.

## Phase 3 — Live Activity (mock ②)

Net-new: there is no `ActivityKit`/`WidgetKit` code and no app-extension target in the project.

- New widget extension target + App Group so the app and extension share session state.
- `ActivityAttributes` with a content state of session name, segment start, accumulated elapsed,
  `isPaused`.
- Lock screen view = the same bar (white pause, grey stop). Dynamic Island compact = dot + elapsed;
  expanded = name, elapsed, pause, stop.
- Use `Text(timerInterval:)` so the clock ticks without pushes, and swap to a frozen string while
  paused — otherwise every second costs an activity update.
- App Intents for pause / resume / stop (interactive buttons are fine on iOS 17).
- This phase is self-contained; ① and ③ can ship without it.

## Phase 4 — Verify

- `xcodebuild -project raceApp.xcodeproj -scheme raceApp -destination 'platform=iOS Simulator,name=iPhone 17' build`
- `xcrun simctl launch "iPhone 17" com.goodproductslab.raceApp -demo -record` — reinstall the built
  .app first or you run the stale build.
- Check both orientations (rotate via the Simulator toolbar button; the Device ▸ Rotate menu is
  disabled unless Simulator is frontmost).
- Walk: record → collapse → pause from the bar → resume → open → pause from the dashboard →
  stop. Confirm the session lands with the right duration and segment count.

## Risks

- **Phase 0 is the gate.** Segments touch the manifest, the store, export and the sessions list.
  Everything visual is cheap by comparison.
- Backward compatibility: existing manifests have no `segments`; decode to a single segment from
  `startedAtUTC` + `durationSeconds`.
- Background behaviour: `applicationDidEnterBackground` currently assumes recording or not.
  Paused-in-background needs deciding — probably keep the session open and the Live Activity up.
- **A paused session does not survive the app being killed.** Recovery claims `isLive` sessions, so
  pause → app killed by iOS → reopen leaves the session finalized as `.recovered` rather than
  paused-and-resumable. Observed for real in the simulator. That is the safe default (the data is
  closed and kept, nothing is lost but the ability to continue in the same session), and resuming
  across a relaunch would only ever work when the device itself has not rebooted, because segment
  times are monotonic uptime. Worth a decision before this ships: a driver who pauses for a
  30-minute lunch may well come back to a closed session.
