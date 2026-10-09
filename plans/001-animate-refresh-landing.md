# 001 — Animate the refresh landing

- **Status**: TODO
- **Commit**: 824d428
- **Severity**: HIGH
- **Category**: Missed opportunities / State indication
- **Estimated scope**: 1 file, 1 line

## Problem

When a portal read lands, the new numbers replace the old ones with no
animation transaction, so every `.contentTransition(.numericText())` in the app
(`AttendanceView.swift:83`, `AttendanceView.swift:194`, `TodayView.swift:396`,
`SubjectView.swift:54`) and the `Meter` width change (`Theme.swift:465`) are
dead on this path. They only run on the hand-tick path, because `mark()` wraps
its change in `withAnimation`.

```swift
// App/Views/RootView.swift:488 — mark(): already correct
withAnimation(Motion.ui.reduced(reduceMotion)) { snapshot = snap }
```

```swift
// App/Views/RootView.swift:536-540 — refresh(): current
            Store.save(snap)
            snapshot = snap
            picked = nil
            tick = Date()
            rescheduleReminders()
```

`portal.begin`'s `onDone` fires up to four times per refresh (rows → timetable
→ finish → register/LMS partial), so this is the moment you check "did my
number go up", repeated.

## Target

Same call `mark()` already uses, on the one line that publishes the snapshot:

```swift
            Store.save(snap)
            withAnimation(Motion.ui.reduced(reduceMotion)) { snapshot = snap }
            picked = nil
            tick = Date()
            rescheduleReminders()
```

`Motion.ui` = `Animation.spring(duration: 0.38, bounce: 0)`. With Reduce Motion
on, `.reduced` swaps in `Motion.gentle` = `Animation.easeOut(duration: 0.2)`.
Do not add any new animation value.

## Repo conventions to follow

- Motion is defined once in `App/Theme.swift:110-127` (`enum Motion`,
  `Animation.reduced(_:)`). Never write a raw `.spring(...)`/`.easeOut(...)` at a call site.
- Exemplar: `RootView.swift:488`.

## Steps

1. In `App/Views/RootView.swift`, inside `refresh()`'s `portal.begin` closure,
   replace the single line `snapshot = snap` (right after `Store.save(snap)`)
   with `withAnimation(Motion.ui.reduced(reduceMotion)) { snapshot = snap }`.
   Leave `picked = nil`, `tick = Date()` and `rescheduleReminders()` outside it.

## Boundaries

- Do NOT touch `Portal.swift` or the merge logic above the `Snapshot(` initialiser.
- Do NOT wrap `picked`/`tick` in the animation (the 30s clock tick must stay unanimated).
- Do NOT add `.animation(...)` modifiers anywhere else.
- If `snapshot = snap` is not at that spot (drift), STOP and report.

## Verification

- **Mechanical**: `node .claude/skills/verify/run.mjs` passes (unchanged — no maths touched). Run the `swift-lint` agent on the diff. Push; the Actions build is the only compiler and must go green.
- **Feel check** (sideload; there is no slow-mo on device, so screen-record and scrub frame by frame): pull a refresh with changed numbers (or use `-demo` if a changed fixture exists).
  - Attendance: the per-subject number rolls rather than cuts, and the meter bar slides to its new width; both settle in ~0.4s with no overshoot.
  - Overall % in the Attendance header rolls.
  - Four partial lands in a row do not produce a visible stutter or restart.
  - Settings → Accessibility → Motion → Reduce Motion ON: numbers cross-fade in ~0.2s, no bar slide across the screen.
- **Done when**: a refresh that changes a number visibly animates it, and a first-ever load (skeleton → content) looks unchanged.
