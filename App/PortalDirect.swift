import Foundation

/// A `Portal`-shaped data source backed by plain HTTP, not a WKWebView.
///
/// Every call here was confirmed live against a real account on 2026-10-13 -
/// see `PortalAuth.swift`. `Portal` itself is untouched and stays the
/// fallback: this enum controls nothing about it, and `RootView` decides
/// per-refresh which one to use. Deleting the WebView path would be
/// fragility, not simplicity - UPES doesn't document these endpoints and
/// could tighten them without notice.
@MainActor
final class PortalDirect: ObservableObject {
    @Published var busy = false
    @Published var status: String?
    /// Set when there's no usable token and a password is needed. The mobile
    /// login takes a literal `"-"` for its captcha field, so this is a plain
    /// two-field form, not the WebView's captcha page.
    @Published var showingLogin = false
    @Published var loginError: String?

    private var credentials: PortalAuth.Credentials?
    /// Set right after a successful sign-in, so the caller can re-run the
    /// refresh it had to abandon for `needsLogin` without the person tapping
    /// refresh a second time.
    var onSignedIn: (() -> Void)?

    enum DirectError: Error { case needsLogin }

    func login(email: String, password: String) async {
        loginError = nil
        do {
            let creds = try await PortalAuth.login(email: email, password: password)
            PortalAuthStore.save(creds)
            credentials = creds
            showingLogin = false
            onSignedIn?()
        } catch {
            loginError = "Could not sign in. Check your email and password."
        }
    }

    func cancelLogin() {
        showingLogin = false
    }

    /// A valid access token, refreshing or asking to sign in as needed.
    private func token() async throws -> String {
        guard var current = credentials ?? PortalAuthStore.load() else {
            showingLogin = true
            throw DirectError.needsLogin
        }

        if current.isExpiringSoon {
            guard let refreshed = try? await PortalAuth.refresh(current) else {
                PortalAuthStore.clear()
                showingLogin = true
                throw DirectError.needsLogin
            }
            current = refreshed
            PortalAuthStore.save(current)
        }
        credentials = current
        return current.accessToken
    }

    /// Mirrors `Portal.begin`: fetches everything over HTTP and hands back one
    /// `Reading`. Throws `DirectError.needsLogin` when there's no usable
    /// session, so `RootView` can show this class's own login form; any other
    /// failure (network, an endpoint UPES has changed) should be treated by
    /// the caller as "fall back to `Portal`'s WebView".
    func begin(
        knownStudent: String?,
        knownHolidays: [Holiday]
    ) async throws -> Portal.Reading {
        guard !busy else { throw DirectError.needsLogin }
        busy = true
        status = "Signing in."
        defer { busy = false; status = nil }

        let token = try await token()

        status = "Reading your identity."
        let identity = try await PortalGateway.studentIdentity(token: token)

        async let term = try? PortalGateway.currentTerm(token: token, studentId: identity.studentId)
        async let week = try? PortalGateway.timetable(
            token: token, studentCode: identity.studentId,
            from: Date().addingTimeInterval(-3 * 86400),
            to: Date().addingTimeInterval(10 * 86400)
        )
        async let photo = Self.fetchPhoto(token: token, identity: identity)
        async let dueResult = Self.fetchDueDates(token: token, identity: identity)

        let resolvedTerm = await term
        var rows: [AttRow] = []
        var daywise: [DaySession] = []
        var attDiag = "term lookup failed"
        if let t = resolvedTerm {
            do {
                let sessions = try await PortalGateway.detailedRegister(
                    token: token, studentId: identity.studentId,
                    courseFamilyId: identity.courseFamilyId, term: t
                )
                rows = Self.summarize(sessions)
                daywise = sessions.compactMap { s in
                    guard let hit = matchSubject(s.courseName, in: rows) else { return nil }
                    return DaySession(subject: hit.key, date: s.date, time: s.time, present: s.present)
                }
                attDiag = "\(rows.count) subjects, \(sessions.count) sessions"
            } catch {
                attDiag = "register failed: \(error)"
            }
        }

        let weekSessions = await week ?? []
        var byDay: [String: [Session]] = [:]
        for s in weekSessions {
            guard let d = s.date else { continue }
            byDay[d, default: []].append(s)
        }
        let today = Snapshot.isoDay.string(from: Date())
        let todaySessions = byDay[today] ?? []

        let (due, lmsDiag) = await dueResult

        return Portal.Reading(
            rows: rows, sessions: todaySessions, student: identity.name ?? knownStudent,
            week: byDay, weekDiag: "direct: \(weekSessions.count) sessions in range", termEnd: nil,
            holidays: knownHolidays, daywise: daywise, attDiag: attDiag,
            photo: await photo,
            deadlines: due, lmsDiag: lmsDiag,
            courses: nil, faculty: [:]
        )
    }

    private static func fetchDueDates(
        token: String, identity: PortalGateway.StudentIdentity
    ) async -> ([Deadline]?, String) {
        do {
            let due = try await PortalLMS.dueDates(token: token, studentId: identity.studentId)
            return (due, "\(due.count) items due")
        } catch {
            return (nil, "lms failed: \(error)")
        }
    }

    /// One `AttRow` per course, folding the register's per-session rows back
    /// into totals - the summary endpoint exists too, but the register
    /// already has everything needed and this avoids a second request.
    private static func summarize(_ sessions: [PortalGateway.SessionRow]) -> [AttRow] {
        var counts: [String: (attended: Int, total: Int)] = [:]
        for s in sessions {
            var c = counts[s.courseName] ?? (0, 0)
            c.total += 1
            if s.present { c.attended += 1 }
            counts[s.courseName] = c
        }
        return counts.map { AttRow(key: $0.key, attended: $0.value.attended, total: $0.value.total) }
    }

    private static func fetchPhoto(token: String, identity: PortalGateway.StudentIdentity) async -> String? {
        guard let p = identity.profilePicture,
            let data = try? await PortalGateway.profilePhoto(
                token: token, containerName: p.containerName,
                blobRelativePath: p.filePath, actualFileName: p.actualFileName
            )
        else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}
