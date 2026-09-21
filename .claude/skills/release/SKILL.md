---
name: release
description: Cut a release - verify, bump MARKETING_VERSION, commit, push to main, watch CI, report the build number and the IPA URL. Pushing to main cuts a GitHub release automatically, so this is the whole ritual in one place.
disable-model-invocation: true
---

# release

Side effects: a commit, a push to `main`, a public GitHub release. Never run
this because it seems implied. It runs when the owner asks for it.

## Before anything

```bash
node .claude/skills/verify/run.mjs
```

Non-zero exits the release. There is no Swift compiler on this machine, so
this suite plus CI is the whole safety net — do not push past a failure to
"see if CI is happier".

Then confirm the tree is what you think it is:

```bash
git status --short && git log --oneline -3
```

## 1. Decide the version

`MARKETING_VERSION` lives in `project.yml` and is bumped **by hand, only when
a release adds something**. A fix that adds nothing user-visible ships on the
build number alone — leave the version where it is.

The build number is the CI run number, passed in on the `xcodebuild` line.
Nothing sets it here.

Read the current value:

```bash
grep MARKETING_VERSION project.yml
```

If it needs bumping, edit `project.yml`. `check-project.mjs` will refuse the
edit if `MARKETING_VERSION` disappears or `Info.plist` lands under `sources:`.

## 2. Update STATUS.md

`STATUS.md` records which build is on the phone and what is actually proven.
A release that changes what the app does changes that file. Update the
shipping line and anything the release makes untrue.

## 3. Commit

Write the message the way this repo writes them: lowercase, a whole sentence,
what it does for the person holding the phone — not what it does to the code.
Look at `git log` before writing one.

```
Let a read that found nothing say so
Match the LMS to your own teachers, and their folders
```

## 4. Push

```bash
git push origin main
```

Pushing to `main` cuts a GitHub release automatically via
`.github/workflows/build-ipa.yml`. The IPA is **unsigned by design** — a
sideloader re-signs it.

## 5. Watch it

```bash
gh run watch --exit-status
```

If it fails, read the log before touching anything:

```bash
gh run view --log-failed
```

## 6. Report back

Give the owner three things and stop:

- the version and the build number (`gh run list -L 1`)
- the release URL (`gh release list -L 1`)
- one line on what changed

They sideload it themselves. A re-signed sideload is a reinstall, which
clears the local notification queue — `Notify.swift` reschedules on launch for
exactly this reason, so nothing is needed from you there.
