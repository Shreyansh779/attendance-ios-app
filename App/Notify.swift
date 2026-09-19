import Foundation
import UserNotifications

/// A reminder before each class, built from the cached timetable.
///
/// Local notifications only: no entitlement, no app extension, so the
/// free-tier signing this project depends on still works. (A Live Activity
/// would be the better experience and is exactly what the extension ban rules
/// out — see CLAUDE.md.)
enum Notify {
    /// How long before the class starts.
    static let lead = 30

    /// iOS keeps at most 64 pending local notifications per app and silently
    /// drops the rest, so schedule a little under that and let each refresh
    /// top the queue back up.
    private static let maxPending = 60

    /// "2026-09-19" + "03:00 PM" -> a real Date. Fixed locale, for the same
    /// reason `Snapshot.isoDay` has one.
    private static var stamp: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// Asked after the first successful read rather than on launch, so the
    /// request arrives when the classes it is about are already on screen.
    static func authorise() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Replaces the whole pending queue from the cached week.
    ///
    /// Called after every refresh and on launch: a sideloaded app is reinstalled
    /// roughly weekly when the certificate is re-signed, and a reinstall clears
    /// pending notifications. Rescheduling on launch makes that invisible.
    static func reschedule(from snap: Snapshot, terms: [String: Term], rows: [AttRow]) async {
        let centre = UNUserNotificationCenter.current()
        guard await authorise() else { return }
        centre.removeAllPendingNotificationRequests()

        let now = Date()
        let fmt = stamp
        var scheduled = 0

        for session in snap.upcoming(from: now) {
            guard scheduled < maxPending,
                let date = session.date,
                let start = fmt.date(from: "\(date) \(session.start)")
            else { continue }

            let fire = start.addingTimeInterval(TimeInterval(-lead * 60))
            guard fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = session.subject
            content.body = body(for: session, terms: terms, rows: rows)
            content.sound = .default

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fire
            )
            let request = UNNotificationRequest(
                identifier: "\(date)|\(session.start)|\(session.subject)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            try? await centre.add(request)
            scheduled += 1
        }
    }

    /// Where it is, when it is, and — only when it actually matters — what it
    /// costs to miss. A reminder that nags about every class trains you to
    /// swipe them all away.
    private static func body(
        for session: Session, terms: [String: Term], rows: [AttRow]
    ) -> String {
        var parts: [String] = []
        parts.append(session.online ? "Online classroom" : "Room \(session.room ?? "not listed")")
        parts.append("in \(lead) min")

        if let row = matchSubject(session.subject, in: rows) {
            let budget = row.budget
            if budget.state == .short {
                if let term = terms[row.key], !term.reachable {
                    parts.append("\(THRESHOLD)% is out of reach")
                } else {
                    parts.append("you need \(budget.value) more")
                }
            }
        }
        return parts.joined(separator: " · ")
    }
}
