# 002 — Press feedback on the last un-styled tappables

- **Status**: DONE
- **Commit**: 824d428
- **Severity**: MEDIUM
- **Category**: Missed opportunities / Feedback
- **Estimated scope**: 3 files; parts A (2 one-line edits) and B (timetable row, riskier)

## Problem

`PressableStyle` exists because "`.plain` … draws no press state at all: a tap
produced no acknowledgement until the screen itself changed"
(`Theme.swift:137-141`). Three tappables still do exactly that:

```swift
// App/Views/TodayView.swift:315-317 — Due rows
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
```

```swift
// App/Views/LmsView.swift:181-187 — LMS items
                                        Button {
                                            onOpen(item.url)
                                        } label: {
                                            Row(item: item)
                                        }
                                        .buttonStyle(.plain)
```

```swift
// App/Views/TimetableView.swift:322-329 — end of Row.body
            .slab(
                fillFor(k),
                radius: 26,
                pad: EdgeInsets(top: k.live ? 22 : 18, leading: 20, bottom: k.live ? 22 : 18, trailing: 20)
            )
            .contentShape(Rectangle())
            .onTapGesture { if tappable { onTap() } }
```

## Target

**Part A (do first, safe):** swap the style on the two existing Buttons.

```swift
.buttonStyle(.pressableCard)   // TodayView.swift:316 and LmsView.swift:186
```

`pressableCard` = `PressableStyle(scale: 0.99)`: scale 0.99, opacity 0.88 on
press, `Motion.press` (`Animation.spring(duration: 0.22, bounce: 0)`), and it
already no-ops the scale under Reduce Motion.

**Part B (timetable row):** the row only acknowledges a press when it actually
does something (`tappable`, i.e. today). Turn `Row.body` into a conditional:

```swift
        @ViewBuilder
        var body: some View {
            if tappable {
                Button(action: onTap) { card }
                    .buttonStyle(.pressableCard)
            } else {
                card
            }
        }

        private var card: some View {
            HStack(alignment: .top, spacing: 15) {
                // ... existing HStack contents, unchanged ...
            }
            .slab(
                fillFor(k),
                radius: 26,
                pad: EdgeInsets(top: k.live ? 22 : 18, leading: 20, bottom: k.live ? 22 : 18, trailing: 20)
            )
            .contentShape(Rectangle())
        }
```

(`.onTapGesture` is removed; the Button replaces it. Non-tappable days keep no press state, because a press that does nothing is a lie.)

## Repo conventions to follow

- Exemplars: `DayStrip` buttons use `.buttonStyle(.pressableCard)` (`TodayView.swift:491`); `AttendanceView.swift:40`, `LmsView.swift:38`.
- Do not write a new ButtonStyle; use `.pressableCard`.

## Steps

1. Part A: in `TodayView.swift` (struct `Due`), change `.buttonStyle(.plain)` → `.buttonStyle(.pressableCard)`. Same in `LmsView.swift` (`CourseView`, the `Button { onOpen(item.url) }`).
2. Commit Part A alone.
3. Part B: in `TimetableView.swift` struct `Row`, rename the current `body` content into a `private var card: some View` (everything except the final `.onTapGesture`), and add the `@ViewBuilder var body` shown above.
4. Commit Part B separately (own revertible commit).

## Boundaries

- Do NOT change `.buttonStyle(.plain)` on "Clear cached data" (`SettingsView.swift:193`): destructive, rare, behind a confirmation dialog.
- Do NOT touch `PressableStyle` or `Motion`.
- Do NOT add `.disabled(...)` to the timetable Button (it dims the label).
- Do NOT keep an `.onTapGesture` alongside the Button.
- Part B risk: the row contains a nested "Join" `Button` (`.pressable`). If, on device, tapping Join also fires the row tap or scales the whole row, REVERT Part B only and report; Part A stands alone.

## Verification

- **Mechanical**: `node .claude/skills/verify/run.mjs`; `swift-lint` agent on the diff; push and the Actions build must go green.
- **Feel check** (device, screen-record and scrub):
  - Due row, LMS item: on touch-down the row dips to 0.99 / 0.88 opacity within one frame and eases back (~0.22s) with no overshoot.
  - Timetable (today): the row dips on touch-down; tapping still jumps to Today with the class pinned; swipe-to-mark (Missed/Attended/Clear) still works and does not trigger the tap.
  - Timetable (other day): rows give no press state and do nothing, as before.
  - Tapping "Join" on a hybrid class opens the link and does NOT also navigate to Today.
  - Reduce Motion ON: opacity dip only, no scale.
- **Done when**: every card-shaped tappable except Settings' destructive row has a press state, and swipe actions and Join still work.
