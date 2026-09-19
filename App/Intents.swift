import AppIntents
import Foundation

/// Siri, Shortcuts and Spotlight, without an app extension.
///
/// App Intents live in the main target, so none of this costs a second bundle
/// identifier and the free-tier signing is untouched (see CLAUDE.md). The
/// build log used to say "No AppIntents.framework dependency found" — this is
/// what it was looking for.
///
/// Every intent reads the cached snapshot rather than touching the portal: the
/// portal needs a captcha, so there is no answer to be had without the user.

// MARK: - Shared reading

private struct Reading {
    let summary: Summary
    let terms: [String: Term]
    let rows: [AttRow]
    let snapshot: Snapshot
}

private func currentReading() -> Reading? {
    guard let snap = Store.load(), !snap.rows.isEmpty else { return nil }
    let rows = applyMarks(snap.rows, snap.marks)
    let now = Date()
    var terms: [String: Term] = [:]
    if let end = snap.termEnd, end >= Snapshot.isoDay.string(from: now) {
        terms = termMap(rows: rows, upcoming: snap.upcoming(from: now))
    }
    return Reading(summary: Summary(rows), terms: terms, rows: rows, snapshot: snap)
}

private let nothingSaved =
    "Nothing saved yet. Open Today and refresh from the portal first."

// MARK: - Where do I stand?

struct AttendanceSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Check my attendance"
    static var description = IntentDescription(
        "Your overall attendance, and the subject closest to dropping below the threshold."
    )
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = currentReading() else { return .result(dialog: "\(nothingSaved)") }

        let pct = String(format: "%.1f", r.summary.overall.pct)
        var said = "You are at \(pct) percent overall, \(r.summary.attended) of \(r.summary.total)."

        if let worst = r.summary.blocker {
            let b = worst.budget
            said += " \(worst.key) is holding you back — it needs \(b.value) more."
            if let t = r.terms[worst.key] {
                said += t.reachable
                    ? (t.clears.map { " Attend every one and it clears on \(spoken($0))." } ?? "")
                    : " With only \(t.remaining) left, \(THRESHOLD) percent is out of reach."
            }
        } else {
            said += " Everything is above \(THRESHOLD) percent."
        }
        return .result(dialog: "\(said)")
    }
}

// MARK: - Can I skip?

struct CanISkipIntent: AppIntent {
    static var title: LocalizedStringResource = "Can I skip today"
    static var description = IntentDescription(
        "Whether today's remaining classes are safe to miss."
    )
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = currentReading() else { return .result(dialog: "\(nothingSaved)") }

        let now = Date()
        let mins = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        let day = shapeDay(
            sessions: r.snapshot.sessions(for: now), rows: r.rows, nowMin: mins
        )
        let left = day.filter { !$0.past }

        guard !left.isEmpty else {
            return .result(dialog: "Nothing left today.")
        }

        var risky: [String] = []
        var safe = 0
        for klass in left {
            guard let row = klass.att else { safe += 1; continue }
            if row.budget.state == .short || (r.terms[row.key]?.skippable ?? 1) == 0 {
                risky.append(klass.subject)
            } else {
                safe += 1
            }
        }

        if risky.isEmpty {
            return .result(dialog: "Yes — all \(left.count) of today's remaining classes have room to spare.")
        }
        let names = risky.joined(separator: ", ")
        let verdict = safe > 0
            ? "Not really. \(names) cannot afford it, though the rest can."
            : "No. \(names) cannot afford it."
        return .result(dialog: "\(verdict)")
    }
}

// MARK: - What is next?

struct NextClassIntent: AppIntent {
    static var title: LocalizedStringResource = "What is my next class"
    static var description = IntentDescription("The next class today, and where it is.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = currentReading() else { return .result(dialog: "\(nothingSaved)") }

        let now = Date()
        let mins = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        let day = shapeDay(
            sessions: r.snapshot.sessions(for: now), rows: r.rows, nowMin: mins
        )

        if let live = day.first(where: { $0.live }) {
            let place = live.online ? "online" : "in room \(live.room ?? "unknown")"
            return .result(dialog: "\(live.subject) is on now, \(place), for another \(live.s1 - mins) minutes.")
        }
        guard let next = day.first(where: { !$0.past }) else {
            return .result(dialog: "Nothing left today.")
        }
        let place = next.online ? "online" : "in room \(next.room ?? "unknown")"
        let away = next.s0 - mins
        return .result(
            dialog: "\(next.subject) at \(hhmm(next.s0))\(ampm(next.s0)), \(place) — in \(away) minutes."
        )
    }
}

// MARK: - Spoken dates

/// "2026-10-08" -> "8 October", because Siri reading out an ISO string is
/// worse than not answering.
private func spoken(_ iso: String) -> String {
    guard let d = Snapshot.isoDay.date(from: iso) else { return iso }
    return d.formatted(.dateTime.day().month(.wide))
}

// MARK: - Shortcuts

struct TodayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AttendanceSummaryIntent(),
            phrases: [
                "What is my attendance in \(.applicationName)",
                "Check my attendance in \(.applicationName)",
            ],
            shortTitle: "Attendance",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: CanISkipIntent(),
            phrases: [
                "Can I skip today in \(.applicationName)",
                "Can I skip class in \(.applicationName)",
            ],
            shortTitle: "Can I skip",
            systemImageName: "questionmark.circle.fill"
        )
        AppShortcut(
            intent: NextClassIntent(),
            phrases: [
                "What is my next class in \(.applicationName)",
                "Next class in \(.applicationName)",
            ],
            shortTitle: "Next class",
            systemImageName: "clock.fill"
        )
    }
}
