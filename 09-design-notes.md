# Design Notes — token mapping for Phase 5 (v0.1)

Source of truth: [design/handoff-live-data-v1/README.md](design/handoff-live-data-v1/README.md) + the interactive prototype (`Live Data App.dc.html` — open in a browser). This file records the **implementation decisions** for translating the HTML design to SwiftUI, per the product owner's instruction: **native iOS components wherever possible; the HTML defines the custom look (colors, layout, numeral typography), not the widgets.**

## Native substitutions (from the handoff + our choices)

| Prototype element | Native implementation |
|---|---|
| Tab bar (custom SVG icons) | `TabView` + SF Symbols: `record.circle`, `waveform.path.ecg`, `list.bullet`, `antenna.radiowaves.left.and.right`; hidden while recording via `.toolbar(.hidden, for: .tabBar)` |
| Saira Condensed numerals | Bundle **Saira Condensed** (Google Fonts, OFL — license permits embedding) for the giant numerals only; all UI text stays SF Pro (system). Fallback if font vetoed: `.system(design: .rounded)` + `fontWidth(.condensed)` |
| Map trace | MapKit `MapPolyline`, dark map style |
| Export | `ShareLink` / `UIActivityViewController` with CSV + JSON items |
| Confirm dialogs, note field, toggles, segmented units | Standard SwiftUI (`confirmationDialog`, `TextField`, `Toggle`, segmented `Picker`) |
| Chips, gauges, tach bar, G-meter | Custom SwiftUI drawing (Canvas/shapes) — this is the "custom design" part |

## Color tokens (SwiftUI asset/Color extension)

```
bgDashboard  #000000        bgScreen   #0B0C0F        sheet      #1A1C21
textPrimary  #F2F5F7        muted      white @ .55/.4/.35/.3
accentCyan   #64D2FF  (gear, links, primary)     green  #32D74B  (throttle, ok)
recordRed    #FF453A  (REC, redline, destructive) amber #FFD60A  (peaks, stale, warnings)
cardBg       white @ .045   cardBorder white @ .08   hairline white @ .08
```

## Key numbers

- Numeral scale: 168 (landscape RPM) / 124–128 / 84–104 / 25–30 / 16–20; line-height 0.85, tabular digits, tracking −1 on giants.
- Micro-labels: 9–11pt, weight 500, tracking 1–2, uppercase.
- Redline 7,500; tach fill turns red within 700 rpm of redline.
- G-meter: 63pt/g portrait (188pt circle), 32pt/g landscape mini; trail 40 points; peak-hold amber ring. Peaks reset **per session** (not per lap — prototype sim only).
- Screen padding 22–24; card radius 10–14; chips 6–8; sheet 24; hit targets ≥44pt (START 140pt, STOP 54pt).
- Animation: bar fills 60–80ms linear; REC dot 1.2s opacity pulse; nothing else animates on the dashboard.
- Stale rule everywhere: "—" at white/.3 — never a fake zero; slow-loop values show age when >10s.

## Gear derivation constants (from handoff, ND2 6MT)

Ratios [5.087, 2.991, 2.035, 1.594, 1.286, 1.000], final drive 2.866 — feeds `speed/RPM` gear inference.

## Open items for Phase 5

- Verify Saira Condensed renders acceptably at 168pt on device vs SF condensed variants; pick once, early.
- Landscape reference is 874×402 (iPhone Pro Max-class); confirm scaling behavior on smaller phones.
