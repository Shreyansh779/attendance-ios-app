# Where things stand

Written 21 Sep 2026. `CLAUDE.md` explains how the app works and why; this file
says what state it is in. If you are a new session, read both.

## The app

**Today** — an attendance tracker for the UPES student portal, sideloaded onto
one iPhone. SwiftUI, iOS 26, XcodeGen (no `.xcodeproj` in the repo), built
unsigned by GitHub Actions and published as an IPA on a release per run.

Shipping: **2.0 (build-95)**. `MARKETING_VERSION` in `project.yml` is bumped by
hand when a release adds something; the build number is the CI run number,
passed in on the `xcodebuild` line. Settings → Data shows both, so a bug report
can start from which build is actually on the phone.

Four screens: **Today**, **Timetable**, **Attendance**, **LMS**.

## What a refresh does, in order

1. Loads the **dashboard URL** — never the site root. With a live session the
   root redirects to `/oneportal/app/auth/login` and parks there for good, so
   starting there demanded a password that was not needed. The login sheet is
   held back until the route actually says `auth/login`.
2. Attendance rows off the dashboard card, handed over the moment they settle.
3. The timetable, from the JSON payload the scheduler page fetches and then
   renders none of. Sixty days back as well as the term ahead. Also yields the
   **teacher map** — subject to the teachers who take your classes, which is the
   only place in the portal that says so.
4. Holiday calendar and profile name, only when not already known.
5. Then, off the critical path, after the read has already finished:
   the **register** (per-day attendance) and the **LMS**.

## The portal, as established by live investigation

Do not guess at this page again. All of it was confirmed in a real browser.

- The register's search form **cannot** be driven: its date inputs are
  `readonly`, so only the calendar popup can set them, and the results grid is
  two tables with the headers in one and the rows in the other. Four builds went
  into trying. The page itself posts to
  `/apigateway/student-attendance/studentattendancesummary`, which takes the
  whole course list at once and answers with JSON.
- Requests need `x-applicationname: connectportal`,
  `x-appsecret: ku7GUMtyT8er51rTfTc7HC`, `x-requestfrom: web` and
  `x-studentUniqueId` on top of the bearer token. The appsecret is a constant
  out of the portal's own public bundle, not a credential.
- The token and student id live in `localStorage` under obfuscated keys, so the
  scrapers find them by the *shape* of the value, never by key name.
- Endpoints that exist and answer but are **empty**: exam schedule
  (`/integratons/api/data/exam-pro`), daily diary
  (`/curriculums/api/dailydiary`). Worth re-checking in exam season.
- Also present and unused: circulars, feedback, fees, hostel, placement.

## The LMS

Coursework is not on the portal at all. The nav's "LMS" tile posts to
`/sso/user/oauth2/access-lms` for a **one-shot** Moodle login URL; the webview
follows it and Moodle answers the rest from its own AJAX endpoint. The key is
spent on use, so `lmsKey` asks exactly once however often it is polled.

A course on this Moodle is **one top-level section per teacher**, each holding
**subsections as folders** (`parentsectionid` is the link). `uservisible` hides
most of the other nineteen teachers' material but *not all of it*, so sections
are matched by name against the teacher map from the timetable — handed over on
`window.__mine`, because the timetable is on the other origin. A section
matching nobody is kept only when it does not look like a person's name, which
is what keeps the sections a course shares with every batch.

Verified live: 10 courses, 20 items. Cryptography shows Ayush Gurjar only; OOAD
shows both Kaustubh Ijardar and Manupriya Darshani; Ethical Hacking shows
Unit-1 / Text Books / Lab as folders under Navin Upadhyay; Probability keeps
the shared PEMC section.

Tapping an item opens it **inside the app's own webview** — the Moodle session
exists nowhere else, so a link handed to Safari lands on a login form nothing
gets past. If the session has lapsed it is rebuilt underneath, and if the
portal has signed out too its login page appears in the same cover and the link
opens by itself once you are through.

The Today screen's **Due** card is the Moodle calendar feed filtered to the same
course items, because that feed knows nothing about sections and otherwise
hands over every assignment in every course. **Right now it is empty and that
is correct** — the only two dated assignments belong to Richa Kumari, who does
not teach you.

## Two bugs worth not reintroducing

- A **navigation bar insets a scroll view** it finds below it but lays a plain
  stack out from the top of the safe area. Three separate "the title is drawn
  over my content" bugs came from this. Every screen's body is a `ScrollView`.
- **`nil` is not `[]`.** Merging a read with "keep the cached value if this one
  came back empty" conflates *the read did not happen* with *the read happened
  and there is nothing*. `Reading.deadlines` and `Reading.courses` are optional
  for exactly this reason.

## How work gets verified

There is no Swift toolchain on this machine, so:

- `node .claude/skills/verify/run.mjs` — the only test suite. Half of it
  executes the real scraper blobs out of `Scrapers.swift`; half is a
  transcription of the Swift maths, pinned to the exact Swift lines so drift
  fails the suite rather than passing silently.
- `.claude/hooks/check-scrapers.mjs` — a PostToolUse gate that parses every JS
  blob in `Scrapers.swift`. A typo there would otherwise cost a full
  push/CI/sideload cycle to discover.
- **CI is the compiler.** Every change is its own revertible commit, pushed, and
  the Actions run is what says whether it built.
- `.github/workflows/shots.yml` — manual only (macOS runners bill 10x). Boots a
  simulator, launches with `-demo` (the fixture in `App/Demo.swift`, DEBUG
  only), and photographs all six screens. Dark only, because the app is. This
  is how visual bugs get found without anyone photographing a phone.

## Open / unverified

- The committed PNGs in `shots/` predate the LMS tab and the sparkline
  removal. Re-run the Screenshots workflow before trusting them.
- A leftover from an earlier session: the scheduled task
  `headroom-default-startup` is still registered on this machine and needs
  Administrator to remove.

## Standing constraints

- **Never** enter the portal credentials or solve its captcha. The user logs in
  by hand, in the browser pane or in the app's login sheet.
- Deletions go to the Recycle Bin, never hard-deleted.
- Blast radius stays inside this repo and the GitHub remote.
- Two sandbox denials stand and must not be worked around: "Expose Local
  Services" and "Traffic Redirection".
- Write back as little as possible; the user is paying for tokens.
