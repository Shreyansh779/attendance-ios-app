# Animation plans

Written against commit `824d428`. Source: a read-only sweep for places that
should animate but don't (the app's existing motion is otherwise sound). Each
plan is self-contained.

| # | Title | Severity | Status | Files |
| --- | --- | --- | --- | --- |
| 001 | Animate the refresh landing | HIGH | TODO | `RootView.swift` |
| 002 | Press feedback on the last un-styled tappables | MEDIUM | TODO | `TodayView.swift`, `LmsView.swift`, `TimetableView.swift` |
| 003 | Show the refresh icon working | MEDIUM | TODO | `RootView.swift` |
| 004 | Slide the pinned-class ring | LOW | TODO | `TodayView.swift` |
| 005 | Fade the LMS link cover | LOW | TODO | `RootView.swift` |
| 006 | Confirm the diagnostic Copy button | LOW | TODO | `SettingsView.swift` |
| 007 | Animate the loading ↔ empty swap | LOW | TODO | `RootView.swift` |

## Order

001 → 002A → 003 → 007 → 005 → 004 → 006 → 002B.

- All plans are independent. 001, 003, 005 and 007 touch different regions of `RootView.swift`; line numbers drift as earlier plans land, so locate by the quoted code, not the line number.
- 002 is two commits: Part A (two one-line style swaps) first; Part B (timetable row becomes a `Button`) last, because it is the one that can misbehave with the nested Join button and swipe actions.
- Project rule: one plan = one revertible commit, pushed; the Actions run is the compiler. There is no local Swift toolchain, so run the `swift-lint` agent on each diff and `node .claude/skills/verify/run.mjs` before pushing.
- Do not trigger the Screenshots workflow for these (macOS runners bill 10x); feel-check on the sideloaded build by screen-recording and scrubbing frame by frame.
- Any plan whose step doesn't match the code: stop and report.
