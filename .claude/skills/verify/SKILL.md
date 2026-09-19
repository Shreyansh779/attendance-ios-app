---
name: verify
description: Run this project's only test suite - syntax-checks and executes the JavaScript scrapers embedded in Scrapers.swift, and brute-forces the attendance arithmetic. Use after any change under App/, before committing, and whenever the attendance maths, the subject matcher, or a scraper blob is touched. There is no Swift compiler on Windows, so this is the only check that runs locally.
---

# verify

```bash
node .claude/skills/verify/run.mjs
```

Exits non-zero on failure. No dependencies beyond node.

## Why this exists

Two things about this project make the usual loop unavailable:

- **There is no Swift compiler on the dev machine.** It's Windows; the only
  compiler in existence for this app is the `macos-15` runner in
  `.github/workflows/build-ipa.yml`. "Does it build" costs a push and ~30s.
- **About a third of the app is JavaScript inside Swift raw string literals.**
  `swiftc` sees opaque strings. A broken blob compiles, ships, throws at
  runtime, and gets swallowed by `(try? await eval(...)) ?? nil` into a blank
  screen that looks like a slow portal.

So CI answers "does it compile" and this answers "is it correct".

## What it covers, and how much to trust each half

**REAL** — executes the actual blobs pulled out of `Scrapers.swift`:

- all 11 blobs parse
- `installSpy` keeps `XMLHttpRequest` identity, statics and `instanceof`, and
  leaves later prototype patching (zone.js) working — replacing the global
  instead of patching its prototype is what silently broke the timetable for
  months
- the `sessions` room regex stops before a trailing join URL
- `weekApi` keeps the whole term and reports payload size

**MODELLED** — a transcription of the Swift into JS, because it cannot be run:

- `Budget` across every `(attended, held)` up to 400 held
- `Term` across every `(attended, held, remaining)` up to 120
- `matchSubject` prefers the closest key and refuses a tie
- `shapeDay` never produces a zero-length class

A transcription can drift from its original without anyone noticing, which
would make this half worse than useless. The **PINS** section guards that: it
asserts the Swift still contains the exact formulas transcribed in `run.mjs`.
Change the maths in `Models.swift` or `Matching.swift` and the pins fail,
telling you to update the port. If a pin fails, fix the transcription — do not
delete the pin.

## When it passes and the app is still wrong

This suite cannot see: whether the Swift compiles, whether SwiftUI lays out
sensibly, or whether the portal's real DOM and API still match what the
scrapers assume. The last one changes without warning and shows up as an empty
screen with a `week:` diagnostic in the drawer. Push and read CI for the first,
a device for the rest.
