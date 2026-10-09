# 005 — Fade the LMS link cover instead of cutting

- **Status**: TODO
- **Commit**: 824d428
- **Severity**: LOW
- **Category**: Missed opportunities / Preventing a jarring change
- **Estimated scope**: 1 file (`RootView.swift`, struct `VisitSheet`), ~6 lines

## Problem

While an LMS link signs in, an opaque `Color.bg` + `ProgressView` covers the
webview; when `portal.visitHidden` flips false it vanishes in one frame, cutting
from spinner to a page that may still be painting.

```swift
// App/Views/RootView.swift:615-623 — current
                PortalWebView(webView: portal.webView)
                    .overlay {
                        if portal.visitHidden {
                            ZStack {
                                Color.bg
                                ProgressView()
                            }
                        }
                    }
```

## Target

```swift
                PortalWebView(webView: portal.webView)
                    .overlay {
                        ZStack {
                            if portal.visitHidden {
                                ZStack {
                                    Color.bg
                                    ProgressView()
                                }
                                .transition(.opacity)
                            }
                        }
                        .animation(Motion.gentle, value: portal.visitHidden)
                    }
```

`Motion.gentle` = `Animation.easeOut(duration: 0.2)` (`Theme.swift:119`): short,
opacity only, and already the app's Reduce-Motion-safe form, so no extra
`.reduced` call is needed. The outer always-present `ZStack` carries the
animation so it does not attach to the webview itself.

## Repo conventions to follow

- Tokens: `Motion` in `Theme.swift:110`. Exemplar of conditional + `.transition`: `RootView.swift:381-396` (status banner, `.transition(.soft)` + `.animation(value:)` on the container).

## Steps

1. In `VisitSheet.body` (`RootView.swift`), replace the `.overlay { if portal.visitHidden { ZStack { Color.bg; ProgressView() } } }` with the target above.

## Boundaries

- Do NOT modify `Portal.swift` (`visitHidden` timing is deliberate).
- Do NOT touch `LoginSheet`, the share button's `fetching` spinner swap, or the status text above the webview.
- Do NOT use `.soft` here (a scale on a full-bleed cover shows edges).

## Verification

- **Mechanical**: `swift-lint` agent; push and the Actions build must go green.
- **Feel check** (device, screen-record, scrub):
  - Tap an LMS item: cover fades in ~0.2s over the previous content (or is already up), spinner centred.
  - When the page is ready the cover fades out over ~0.2s, revealing the document; no flash of white, no hard cut.
  - If the portal login appears (`visitHidden = false` early) the cover fades away and the login page is usable without a 0.2s block that eats the first tap more than expected.
  - Reduce Motion ON: unchanged (already opacity only).
- **Done when**: the cover cross-fades both ways and nothing else on the sheet changed.
