# Today

UPES attendance, on the lock screen of your hand. A single-user iOS app that
reads the student portal and answers one question well: *can I skip this
class?*

## Install

**[shreyansh779.github.io/attendance-ios-app](https://shreyansh779.github.io/attendance-ios-app/)** — open it on the phone and tap **Add to SideStore**.

Or add the source by hand. In SideStore, Sources lives inside the **Browse**
tab, not in a tab of its own:

```
https://shreyansh779.github.io/attendance-ios-app/source.json
```

Once the source is added, every build turns up as an update on its own. The
IPA ships **unsigned** by design — SideStore re-signs it with your own
certificate on install.

Prefer to do it by hand? The [latest release](../../releases/latest) has the
IPA; SideStore installs a local file from **My Apps → +**.

## What it does

Four screens. **Today** is the class you are walking to and how much room you
have left in it. **Attendance** is every subject with the number of classes
you can still miss, the day each one clears 75%, and which single subject is
the blocker. **Timetable** pages back through the term as well as forward.
**LMS** is coursework and deadlines, filtered to the teachers your own
timetable says take your classes.

The arithmetic is integer throughout, so no rounding can shift an answer by
one class. Reminders are scheduled on the phone. Nothing leaves it: there is
no server and no account, and the portal session lives in one webview you log
into by hand.

## Building it

There is no `.xcodeproj` in this repo — XcodeGen generates one on CI, and
pushing to `main` cuts a release. The test suite runs locally with node and no
dependencies:

```bash
node .claude/skills/verify/run.mjs
```

[CLAUDE.md](CLAUDE.md) explains how the app works and why it is built this
way. [STATUS.md](STATUS.md) says what state it is actually in — which build is
on the phone, what the portal has been proven to do, and what is unverified.
