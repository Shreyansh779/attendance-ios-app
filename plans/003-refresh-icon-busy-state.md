# 003 — Show the refresh icon working

- **Status**: DONE
- **Commit**: 824d428
- **Severity**: MEDIUM
- **Category**: Missed opportunities / State indication
- **Estimated scope**: 1 file, 1 line (+ 1 fallback)

## Problem

A refresh takes seconds to tens of seconds (`Portal.swift`: poll, timetable
page load, holiday calendar, profile). While `portal.busy` the toolbar button
just goes disabled and grey; the only other signal is the status text pinned to
the bottom edge, far from the thumb that tapped.

```swift
// App/Views/RootView.swift:351-359 — current
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(portal.busy)
                        .accessibilityLabel("Refresh from portal")
                    }
```

## Target

```swift
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.rotate, isActive: portal.busy && !reduceMotion)
                        }
```

System-provided indefinite rotation while `portal.busy` is true; stops when the
core read finishes (`busy = false` in `Portal.finish`, `Portal.swift:1055`).
`busy` is already false during the background register/LMS fetch, so the icon
stops while the "Checking the LMS." status banner may still be showing; that is
intended (the button is usable again). Under Reduce Motion nothing spins and
the existing disabled dimming remains the indicator.

**Fallback** if `.rotate` renders no visible spin for this symbol on device: use
`.symbolEffect(.pulse, isActive: portal.busy && !reduceMotion)` (works on every symbol).

## Repo conventions to follow

- `reduceMotion` is already an `@Environment(\.accessibilityReduceMotion)` on `RootView` (`RootView.swift:96`), reachable from `screen(...)`.
- Exemplar of the Reduce-Motion guard: `Skeleton` (`Theme.swift:452-453`).
- iOS 26 target (the file already uses `.glassEffect`), so iOS 18+ `symbolEffect(.rotate)` is available; no `#available` check needed.

## Steps

1. In `RootView.swift` `screen(...)`, on the `Image(systemName: "arrow.clockwise")` add `.symbolEffect(.rotate, isActive: portal.busy && !reduceMotion)`.

## Boundaries

- Do NOT touch the Settings gear item or `.disabled(portal.busy)`.
- Do NOT add a custom rotation with `withAnimation` / `.rotationEffect` (can't be cancelled cleanly).
- Do NOT add a ProgressView.

## Verification

- **Mechanical**: `swift-lint` agent on the diff; push and the Actions build must go green.
- **Feel check**:
  - Tap refresh: the arrow starts turning immediately and keeps turning until the status banner for the core read clears, then stops without a snap.
  - Tapping again while busy does nothing (still disabled).
  - It does not spin during the background "Checking the LMS." phase.
  - Reduce Motion ON: no spin; icon dims as before.
- **Done when**: the icon visibly signals a read in progress and stops with it.
