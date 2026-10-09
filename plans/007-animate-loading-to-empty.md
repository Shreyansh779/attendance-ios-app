# 007 — Animate the loading ↔ empty-state swap

- **Status**: DONE
- **Commit**: 824d428
- **Severity**: LOW
- **Category**: Missed opportunities / Preventing a jarring change
- **Estimated scope**: 1 file (`RootView.swift`), 2 lines

## Problem

With no saved data the root shows `loadingState` while `portal.busy`, else
`emptyState`. The only animation driver on that ZStack watches `hasData`, which
does not change during the swap, so the skeleton and the empty state cut
instantly in both directions (first run, a failed first read, after Clear
cached data and then Refresh). `loadingState` has `.transition(.soft)` but it
never runs; `emptyState` has none.

```swift
// App/Views/RootView.swift:162-172 — current
            if hasData {
                tabs
                PillBar(route: $route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if portal.busy {
                loadingState
            } else {
                emptyState
            }
        }
        .animation(Motion.ui.reduced(reduceMotion), value: hasData)
```

```swift
// App/Views/RootView.swift:451-452 — end of emptyState
        }
        .padding(.horizontal, 32)
```

## Target

```swift
        }
        .animation(Motion.ui.reduced(reduceMotion), value: hasData)
        .animation(Motion.ui.reduced(reduceMotion), value: portal.busy)
```

```swift
        }
        .padding(.horizontal, 32)
        .transition(.soft)
```

`.soft` = opacity + `scale(0.985)` (`Theme.swift:132`); `Motion.ui` = spring 0.38s,
bounce 0 (Reduce Motion → 0.2s easeOut). Only opacity and a sub-1.5% scale; no slide.

## Repo conventions to follow

- Pattern: conditional view + `.transition(.soft)` + `.animation(Motion.ui.reduced(reduceMotion), value:)` on the container — `RootView.swift:381-396` (status banner), `SettingsView.swift:152-162`.

## Steps

1. In `RootView.body`, immediately after `.animation(Motion.ui.reduced(reduceMotion), value: hasData)` add the same modifier with `value: portal.busy`.
2. In `emptyState`, append `.transition(.soft)` after `.padding(.horizontal, 32)`.

## Boundaries

- Do NOT remove or alter the existing `hasData` animation.
- Do NOT add transitions to `tabs`/`PillBar`.
- Side effect to accept: with data present, `portal.busy` changes now also animate the toolbar button's disabled dimming, which is harmless. If anything else in the tab subtree visibly changes behaviour on refresh start/stop, STOP and report.
- Do NOT touch `Portal.swift`.

## Verification

- **Mechanical**: `swift-lint` agent; push and the Actions build must go green.
- **Feel check**:
  - Fresh install (or Settings → Clear cached data): empty state is there; tap "Open the portal": empty state fades out as the skeleton fades in (~0.4s), no pop.
  - Cancel the login so the read fails: skeleton fades to the empty state, not a cut.
  - With data present, tapping refresh looks identical to before (no layout shift).
  - Reduce Motion ON: 0.2s cross-fade, no scale.
- **Done when**: both directions of the loading ↔ empty swap cross-fade and nothing else moved.
