# Today — UPES attendance, on the lock screen of your hand

A single-user iOS app that scrapes the UPES student portal and answers one
question well: *can I skip this class?*

**Read [STATUS.md](STATUS.md) first.** This file explains how the app works and
why it is built this way. STATUS.md says what state it is actually in — which
build is on the phone, what the portal has been proven to do and not do, what
is unverified, and the constraints that stand whatever the task.

## The two things that will surprise you

**1. There is no Swift compiler on the dev machine.** Development happens on
Windows. The only compiler that exists for this project is the `macos-15`
runner in `.github/workflows/build-ipa.yml`. Every "does it build" costs a push
and ~30 seconds. Write conservatively; you cannot check your work locally.

**2. About a third of the app is JavaScript inside Swift raw string literals.**
`Scrapers.swift` holds 15 blobs in `#"""…"""#`. `swiftc` sees opaque strings and
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
  obvious use case. App Intents would have been fine (main target, no
  extension) but were removed at the owner's request — unused. Don't re-add
  them without asking; Siri, Shortcuts and Spotlight all went with them.
- **No App Group, no entitlements file.** Same reason.
- **Local notifications and EventKit are fine** — neither needs an entitlement.

## Architecture

- `Portal.swift` — one `WKWebView` for the app's lifetime. The portal has a
  captcha, so there is no headless path: the webview goes on screen, the user
  logs in by hand, and the same webview is then read with `evaluateJavaScript`.
  A second webview would share cookies but not `sessionStorage`.
  A refresh starts at `dashboardURL`, never the site root. With a session still
  good the root redirects to `/oneportal/app/auth/login` and *stays there* —
  it will not carry you back in — so starting there meant every refresh
  demanded a password that was not needed. The dashboard URL resumes silently,
  and the login sheet is held back until the route actually says `auth/login`.
- `Scrapers.swift` — the JS. The timetable comes from `weekApi`, which reads the
  payload the page already fetched (`window.__ttData`, stashed by `installSpy`),
  not from rendered HTML. A DOM scraper exists as a fallback. `weekApi` keeps
  sixty days of past sessions as well as the term ahead, so back-paging the
  timetable is not blank.
  `registerStart`/`registerRead` fetch the register — one row per session —
  by asking `/student-attendance/studentattendancesummary` directly. Four
  builds went into driving that page's search form instead, and none of it
  could ever have worked: the date inputs are `readonly`, so only the calendar
  popup can set them, and the results grid is two tables with the headers in
  one and the rows in the other. The endpoint takes every course at once.
  `lmsKey`/`lmsDue`/`lmsCourses` get coursework, which the portal does not
  hold at all: its "LMS" tile posts to `/sso/user/oauth2/access-lms` for a
  **one-shot** Moodle login URL, the webview follows it, and Moodle answers
  the rest from its own AJAX endpoint. The key is spent on use, so `lmsKey`
  asks exactly once however often it is polled. `lmsDue` keeps only `assign`
  and `quiz` — that feed also nags about every file ever uploaded to a
  course. `lmsCourses` reads `core_courseformat_get_state`
  (`core_course_get_contents` is switched off here, and the state carries
  more anyway). A course there is one **top-level section per teacher**, each
  holding **subsections as folders**; `parentsectionid` is the link, and a
  `Subsection` module is only a pointer to a section that arrives on its own,
  so counting it lists everything twice. `uservisible` hides most of the
  other nineteen teachers' material but **not all of it**, so sections are
  matched by name against the teachers the *timetable* says take your classes
  — handed over on `window.__mine`, because the timetable is on the other
  origin. A section matching nobody is kept only when it does not look like a
  person's name, which is what keeps "General" and
  "PEMC(Batches - CCSF (4,5,6,7,8,9)". Courses are filtered to `_Sem5`.
  Anything async parks its answer on a `window` global and is polled, because
  `evaluateJavaScript` cannot wait for a promise.
- `Models.swift` — `Budget` (can I skip?) and `Term` (can I still recover?).
  Integer arithmetic throughout so no rounding can shift an answer by one class.
  Brute-forced against 893,101 combinations in the verify suite.
- `Matching.swift` — ties timetable subject names to attendance rows. Returning
  nil is a valid answer; showing another subject's numbers is not.
- `Notify.swift` — local reminders before each class, plus one end-of-day
  nudge. iOS caps pending local notifications at 64 and silently drops the
  rest, so it schedules 60 and each refresh tops the queue up. It reschedules
  on *launch* too, because a re-signed sideload is a reinstall and a reinstall
  clears the queue.
- `Store.swift` — `UserDefaults`. `Snapshot.history` is one `Stamp` per day the
  portal was read, holding the portal's own rows — not the marked ones, or the
  trend would move when you ticked a box rather than when you attended
  something. `Snapshot.termEnd` is set **only** when a
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

A read hands data over in three instalments, not one: attendance rows the
moment they settle, the timetable when it is scraped, everything else at the
end. Every field a partial cannot fill is left empty, and the merge in
`RootView` keeps whatever the last read established — so a partial can only
add, never clear. `fetchDaywise` and then `fetchDeadlines` run after the read
has already finished, off the critical path: the LMS is a different site, and
while the register was on that path a portal that would not cooperate held
`busy` and the banner hostage, so a read that had in fact succeeded looked
like one that had hung.

The version is `MARKETING_VERSION` in `project.yml`, bumped by hand when a
release adds something; the build number is the CI run, passed on the
`xcodebuild` line. Settings shows both, so a bug report can start from which
build is actually on the phone.

## Design

Three screens, each with its own `NavigationStack` and large title. Not a
drawer, and no longer a `TabView` either: the tab bar is a floating glass
capsule (`PillBar`, draggable), and the screens are a cross-fading `ZStack` —
all three mounted, so paging the timetable survives a trip to Attendance.

Every card is a material with a lit edge and a shadow, never a flat fill, and
`Backdrop` sits behind the lot because glass over one flat colour blurs to
exactly that colour. The surface tokens (`sur`, `surLive`, `surDim`…) are
*tints* laid over a material, not fills — an opaque one collapses the system
back into rectangles. Corners never under 18; the only hairline in the app is
the rule between two rows of one Settings card.

Two faces, both already on the phone: SF Pro for interface text, New York for
screen titles and the one number a screen exists to show. Styrene and Tiempos
cannot be bundled and New York is the closest serif iOS ships. Rationing it is
the point — setting small numbers in it too made the app look like two apps.

Motion lives in `Theme.swift` and nothing overshoots: bounce is earned by a
gesture that carried momentum and there is no such gesture here.
`Animation.reduced(_:)` honours Reduce Motion everywhere.

The app is **dark only** — `UIUserInterfaceStyle` is pinned to `Dark` in
`Info.plist`. There was a light palette; it was computed, contrast-verified,
never once looked at on a device, and deleted. Every token in `Theme.swift` is
now a single value solved against that one ground, and the ink ramp is
contrast-solved so even the dimmest step clears WCAG AA (4.5:1) on every
surface. Do not dim text below `ink4`, and do not introduce a raw hex — a hook
(`.claude/hooks/check-tokens.mjs`) refuses one anywhere under `App/` except
`Theme.swift` itself.

Urgency has three states, not two: mint (fine), amber (short but recoverable),
coral (the blocker, or no longer reachable). Coral is spent on one row, not on
every row that happens to be below the line — when everything is an alarm,
nothing is.

Type scales. Use `View.r(_:_:)`, never `.font(.r(...))`, or the size stops
responding to the reader's text-size setting. Clamped at `accessibility1`.

## Known debt

- The weekly timetable is delivered by the `weekApi` path in practice — if the
  app shows term lines then `termEnd` is set, and only that path sets it. The
  DOM scraper, `agenda`, `nudge` and `spyDump` are the untravelled fallback.
  They are kept deliberately: the portal is not under our control, and deleting
  the recovery path for an external dependency is fragility, not simplicity.
- Classes earlier *today* count as "remaining" in the term maths, so late in the
  day a subject can look one class better off than it is. Errs toward
  "recoverable", which is the safe direction.
- `ponytail:` comments mark deliberate shortcuts with their ceiling.

## Skills a session here should be using

Eight plugins are installed on this machine. Most are for work this project
does not do — documents, spreadsheets, web animation, React Native, charts,
LLM API code. These are the ones that earn their place here, and a session
should reach for them without being asked:

- **`write-swift`** — the one that matters most. There is no Swift compiler on
  this machine, so idiom and concurrency correctness have to come from reading.
  Load it before touching `Portal.swift`, `Store.swift` or anything `async`.
- **`verify`** (in this repo) — the only test suite. Run it before every push.
- **`code-review`** / `agent-skills:code-review-and-quality` — before a push,
  because a push is the only way to find out anything.
- **`apple-design`** — the glass, the springs, the materials and the
  Reduce-Motion handling in `Theme.swift` are all Apple-idiom. It is written
  for the web; read the principles, not the CSS.
- **`impeccable`** and **`ui-ux-pro-max`** — visual work. Both are wired into
  the `ui-review` agent.
- **`llm-council`** — for a decision with real trade-offs, not for routine work.
- **`ponytail`** — forced on by a SessionStart hook. The ladder applies.
- **`karpathy-guidelines`** — surgical diffs, no speculative abstraction.
- **`i-have-adhd`** — the owner's output style. User-invocable only: ask them
  to run `/i-have-adhd`, do not imitate it.

Deliberately **not** for this project: `dataviz`, `mobile-native`, `animate`,
`animate-expo`, `emil-design-eng`, `ask-sonner` (all web or React Native),
`claude-api` (no LLM code here), `security-audit` (single user, no server, no
credentials stored beyond a session cookie), the `docs`/`docx`/`xlsx`/`pptx`/
`pdf` family, and the `design:*` connectors (Figma, Linear, Notion, Slack —
all need OAuth that has never been granted).

## Agents in this repo

- **`swift-lint`** — stands in for the compiler. Run it on the diff before a
  push; a failed CI run costs thirty seconds and a release tag.
- **`ui-review`** — reads `shots/*.png` against the Design rules above. The
  only eye the app gets between CI and a device.
