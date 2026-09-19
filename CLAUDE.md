# Today — UPES attendance, on the lock screen of your hand

A single-user iOS app that scrapes the UPES student portal and answers one
question well: *can I skip this class?*

## The two things that will surprise you

**1. There is no Swift compiler on the dev machine.** Development happens on
Windows. The only compiler that exists for this project is the `macos-15`
runner in `.github/workflows/build-ipa.yml`. Every "does it build" costs a push
and ~30 seconds. Write conservatively; you cannot check your work locally.

**2. About a third of the app is JavaScript inside Swift raw string literals.**
`Scrapers.swift` holds 12 blobs in `#"""…"""#`. `swiftc` sees opaque strings and
validates none of it. A broken blob compiles, ships, throws at runtime, and gets
swallowed by `(try? await eval(...)) ?? nil` into a blank screen that looks like
a slow portal. A `PostToolUse` hook (`.claude/hooks/check-scrapers.mjs`)
syntax-checks every blob on edit — do not disable it.

## Verify before you push

```bash
node .claude/skills/verify/run.mjs
```

The project's only test suite, ~0.4s, no dependencies. Two halves, unequally
trustworthy:

- **Real** — executes the actual scraper blobs out of `Scrapers.swift`.
- **Modelled** — a JS transcription of the Swift maths, because it cannot be run.

A transcription can drift silently, so the suite **pins** the exact Swift
formulas it transcribes. Change the maths in `Models.swift` or `Matching.swift`
and the pins fail, naming the line. Fix the transcription; never delete the pin.

CI answers "does it compile". This answers "is it correct". Nothing answers
"does it look right" except sideloading it.

## Build

XcodeGen generates the project on CI — there is no `.xcodeproj` in the repo.
`Info.plist` is **excluded from `sources`** in `project.yml` on purpose:
`INFOPLIST_FILE` already targets it, and leaving it in makes XcodeGen also add
it to Copy Bundle Resources, so two build commands write the same path and the
build fails after linking. That produced a bundle containing only the binary.

The IPA ships **unsigned** by design; a sideloader re-signs it. Pushing to
`main` cuts a GitHub release automatically.

## Constraints you must not casually break

- **No app extensions.** No widget, no Live Activity, no App Intents extension.
  An extension means a second bundle ID, which breaks the free-tier signing this
  project deliberately protects. This is why there is no widget despite the
  obvious use case. App Intents in the *main* target are fine.
- **No App Group, no entitlements file.** Same reason.
- **Local notifications and EventKit are fine** — neither needs an entitlement.

## Architecture

- `Portal.swift` — one `WKWebView` for the app's lifetime. The portal has a
  captcha, so there is no headless path: the webview goes on screen, the user
  logs in by hand, and the same webview is then read with `evaluateJavaScript`.
  A second webview would share cookies but not `sessionStorage`.
- `Scrapers.swift` — the JS. The timetable comes from `weekApi`, which reads the
  payload the page already fetched (`window.__ttData`, stashed by `installSpy`),
  not from rendered HTML. A DOM scraper exists as a fallback.
- `Models.swift` — `Budget` (can I skip?) and `Term` (can I still recover?).
  Integer arithmetic throughout so no rounding can shift an answer by one class.
  Brute-forced against 893,101 combinations in the verify suite.
- `Matching.swift` — ties timetable subject names to attendance rows. Returning
  nil is a valid answer; showing another subject's numbers is not.
- `Store.swift` — `UserDefaults`. `Snapshot.termEnd` is set **only** when a
  whole-term read succeeded; everything term-aware is gated on it, because
  calling a subject hopeless on the strength of a six-day agenda would be a lie.

## Traps that have already cost real time

- **Never replace a global with a wrapper function** in the injected JS.
  `installSpy` used to do `window.XMLHttpRequest = function(){…}`, which detaches
  the real prototype — zone.js patches the wrapper's empty prototype, Angular
  never runs change detection, and the scheduler renders nothing. Patch
  `prototype` in place. This bug hid for months and looked like a slow portal.
- **Fixed-format `DateFormatter` needs `locale = en_US_POSIX`.** Without it the
  current locale's numbering system applies and a non-Latin-digit region writes
  keys that never match the scrapers' ASCII ones.
- **Regexes anchored with `$`** over-capture. The room regex swallowed a
  trailing join URL into the room name, which the 92pt hero then displayed.
- **`NSURLErrorCancelled` (-999) is not a failure.** It is what WebKit reports
  whenever one load interrupts another, which `fetchWeek`/`fetchStudentName` do
  on purpose twice per read.

## Design

Dark only. Corners never under 18, no borders or hairline rules anywhere,
separation carried by space and tone. Motion lives in `Theme.swift`: Apple's own
figures (drawer = damping 0.8 / response 0.3; general UI critically damped),
with `bounce = 1 - damping`. Bounce is spent only where the gesture carried
momentum. `Animation.reduced(_:)` honours Reduce Motion everywhere.

The ink ramp is contrast-solved — even the dimmest step clears WCAG AA (4.5:1)
on every neutral surface. Do not dim text below `ink4`.

## Known debt

- **Dynamic Type is unsupported** — font sizes are fixed points. The real
  remaining accessibility gap.
- Classes earlier *today* count as "remaining" in the term maths, so late in the
  day a subject can look one class better off than it is. Errs toward
  "recoverable", which is the safe direction.
- `ponytail:` comments mark deliberate shortcuts with their ceiling.
