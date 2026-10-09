# 004 — Slide the pinned-class ring between day-strip chips

- **Status**: TODO
- **Commit**: 824d428
- **Severity**: LOW
- **Category**: Physicality & origin / Spatial consistency
- **Estimated scope**: 1 file (`TodayView.swift`, struct `DayStrip`), ~8 lines

## Problem

The ring marking which class the hero shows is a stroke whose opacity flips
0.85 ↔ 0 on each chip, so it teleports between chips rather than moving. The
app's other selector (`SlideBar`, `Theme.swift:263`) slides its thumb.

```swift
// App/Views/TodayView.swift:486-489 — current (inside DayStrip's Button label)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.ink.opacity(k.id == heroID ? 0.85 : 0), lineWidth: 1.5)
                )
```

The animation driver already exists: `TodayView.swift:43`
`.animation(Motion.ui.reduced(reduceMotion), value: hero?.id)` on the ScrollView.

## Target

One ring, matched across chips:

```swift
// in struct DayStrip, next to the other properties
    @Namespace private var ring

// replacing the overlay at :486-489
                .overlay {
                    if k.id == heroID {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.ink.opacity(0.85), lineWidth: 1.5)
                            .matchedGeometryEffect(id: "ring", in: ring)
                    }
                }
```

It rides the existing `Motion.ui` spring (0.38s, bounce 0) via the transaction
from `.animation(... value: hero?.id)`. Under Reduce Motion that becomes the
0.2s `easeOut`, which for a matched geometry is a quick glide/fade, not zero.
Only geometry and opacity change; no layout.

## Repo conventions to follow

- Motion stays in the existing `.animation(Motion.ui.reduced(...))` at `TodayView.swift:43`; add no new animation value.
- Exemplar of a sliding selection: `SlideBar` (`Theme.swift:263-339`).

## Steps

1. In `TodayView.swift`, struct `DayStrip` (starts `private struct DayStrip: View`), add `@Namespace private var ring`.
2. Replace the `.overlay(RoundedRectangle … opacity(k.id == heroID ? 0.85 : 0) …)` with the conditional `.overlay { if k.id == heroID { … .matchedGeometryEffect(id: "ring", in: ring) } }` above. Keep corner radius 20, `.continuous`, line width 1.5, colour `Color.ink.opacity(0.85)` exactly.

## Boundaries

- Do NOT change chip layout, tints, `.pressableCard`, or `picked` logic.
- Do NOT add a second namespace or move `@Namespace` out of `DayStrip`.
- Do NOT add `.transition`s unless the feel check shows a double-ring ghost (see below).
- If the ring jumps instead of sliding, or two rings are visible mid-travel, add `.transition(.opacity)` to the ringed RoundedRectangle once; if still wrong, REVERT and report.

## Verification

- **Mechanical**: `swift-lint` agent; push and the Actions build must go green.
- **Feel check** (device, screen-record, scrub):
  - Tap chip 3 then chip 1: the ring glides from one to the other in ~0.4s, no overshoot, never two full-strength rings.
  - Tapping the already-pinned chip (returns to following the clock): the ring moves to the clock's class, or fades if no hero.
  - Last class ends → hero nil: ring fades out, does not fly off.
  - Rapid taps across chips retarget smoothly (no restart from the old position).
  - Press feedback on chips (`pressableCard`) still works; ring scales with its chip.
  - Reduce Motion ON: quick fade/glide, no long travel.
- **Done when**: pinning a class moves one ring, not two opacity flips.
