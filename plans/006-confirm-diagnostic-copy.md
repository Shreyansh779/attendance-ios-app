# 006 — Confirm the diagnostic Copy button

- **Status**: TODO
- **Commit**: 824d428
- **Severity**: LOW
- **Category**: Missed opportunities / Feedback
- **Estimated scope**: 1 file (`SettingsView.swift`), ~15 lines

## Problem

Tapping Copy writes the pasteboard and shows nothing, so you cannot tell
whether it worked before pasting a bug report.

```swift
// App/Views/SettingsView.swift:223-233 — current (inside diagnostic(_:_:_:))
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .r(14, .semibold)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassy(Capsule(), soft: false)
                }
                .buttonStyle(.pressable)
```

Up to three diagnostic cards can be on screen (Timetable, LMS, Register), so
the "copied" state must be per card, not one shared Bool.

## Target

State next to the existing `@State`s (`SettingsView.swift:29-30`):

```swift
    /// Which diagnostic card was just copied, by its name; nil when none.
    @State private var copiedName: String?
```

Button:

```swift
                Button {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(Motion.ui.reduced(reduceMotion)) { copiedName = name }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(Motion.ui.reduced(reduceMotion)) {
                            if copiedName == name { copiedName = nil }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedName == name ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        Text(copiedName == name ? "Copied" : "Copy")
                    }
                    .r(14, .semibold)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassy(Capsule(), soft: false)
                }
                .buttonStyle(.pressable)
```

Values: icon swap = system `.replace` content transition; capsule width change
and text swap ride `Motion.ui` (spring 0.38s, bounce 0; Reduce Motion → 0.2s
easeOut). Haptic is fired in the action, not via `.sensoryFeedback(trigger:)`,
which would also fire on the revert; same reasoning as `RootView.swift:481-485`.

## Repo conventions to follow

- `reduceMotion` is already on this struct (`SettingsView.swift:32`).
- Mutating `@State` from `Task { }` has precedent at `SettingsView.swift:137`.
- Exemplar of a text swap with `.soft`/`Motion.ui`: `SettingsView.swift:152-158`.

## Steps

1. Add `@State private var copiedName: String?` beside `testResult`/`clearing`.
2. In `diagnostic(_ name: String, _ text: String, _ why: String)`, replace the Copy button as above. `name` is the function's first parameter, already in scope.

## Boundaries

- Do NOT change what is copied (`text`) or the card layout.
- Do NOT use one shared Bool; key on `name`.
- Do NOT add `.sensoryFeedback` on `copiedName`.
- Do NOT use hex colours (a hook rejects them); `Color.ink` only.

## Verification

- **Mechanical**: `swift-lint` agent; push and the Actions build must go green. (Diagnostic cards only render when a scrape came back thin; if none show on the phone, verify via a `-demo` fixture or note it as unverified visually.)
- **Feel check**:
  - Tap Copy: icon swaps to a checkmark, label to "Copied", light success haptic, capsule resizes smoothly; after ~1.5s it returns to "Copy" with no second haptic.
  - With two cards visible, copying one does not change the other.
  - Tapping again during the 1.5s window keeps "Copied" and does not flicker back early more than once (an earlier timer may revert slightly sooner; acceptable).
  - Paste elsewhere confirms the text really copied.
  - Reduce Motion ON: label swaps with a quick fade, no capsule slide.
- **Done when**: Copy gives visible, haptic, per-card confirmation.
