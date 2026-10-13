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
    /// Why the last refresh fell back to the WebView, if it did - set by
    /// `RootView` from whatever `begin` threw. Nothing else here surfaces
    /// this; without it a fallback is silent and undiagnosable from Settings.
    @Published var lastError: String?

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
            // Saved only on success - a wrong password typed here must never
            // be the thing silentLogin() retries with forever.
            PortalCredentialStore.save(.init(email: email, password: password))
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

    /// A valid access token, refreshing, silently re-logging in with a saved
    /// password, or asking to sign in as a last resort.
    private func token() async throws -> String {
        guard var current = credentials ?? PortalAuthStore.load() else {
            return try await silentLoginOrPrompt()
        }

        if current.isExpiringSoon {
            guard let refreshed = try? await PortalAuth.refresh(current) else {
                PortalAuthStore.clear()
                return try await silentLoginOrPrompt()
            }
            current = refreshed
            PortalAuthStore.save(current)
        }
        credentials = current
        return current.accessToken
    }

    /// The bearer token is gone or dead; a saved email/password is tried
    /// once before falling back to asking in person. A saved password that
    /// no longer works is cleared rather than retried forever - a `-` typed
    /// as "this isn't working" needs the real captcha-gated web login, which
    /// retrying the same bad password here would never reach.
    private func silentLoginOrPrompt() async throws -> String {
        if let saved = PortalCredentialStore.load() {
            if let creds = try? await PortalAuth.login(email: saved.email, password: saved.password) {
                PortalAuthStore.save(creds)
                credentials = creds
                return creds.accessToken
            }
            PortalCredentialStore.clear()
        }
        showingLogin = true
        throw DirectError.needsLogin
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

        var token = try await self.token()

        status = "Reading your identity."
        // `token()` only refreshes pre-emptively, against our own guessed
        // expiry - a token that's actually dead server-side (revoked, or
        // just outlived our guess) sails past that check and 401s here
        // instead. Without this, that 401 is just "a failure," which looks
        // identical to a real endpoint break and sends every refresh to the
        // WebView forever, never giving this class's own login form a
        // chance to run.
        let identity: PortalGateway.StudentIdentity
        do {
            identity = try await PortalGateway.studentIdentity(token: token)
        } catch let error as PortalGateway.GatewayError {
            // Confirmed live as a clean 200 for a valid token, unlike the
            // known-flaky holidays endpoint - so any failure here, 401 or
            // not, reads as "this token is garbage" rather than "UPES's
            // server is having a moment." Seen live as a 500, not a 401, for
            // what was almost certainly a stale token left over from earlier
            // testing - the server doesn't reject it cleanly, but it is not
            // valid. One retry through the same silent-login-or-prompt path
            // `token()` uses, so a saved password gets a chance before
            // anyone's asked to type it again. The refreshed token replaces
            // `token` itself, since every call below this point still uses it.
            credentials = nil
            PortalAuthStore.clear()
            lastError = "\(error)"
            token = try await silentLoginOrPrompt()
            identity = try await PortalGateway.studentIdentity(token: token)
        }

        // The timetable range depends on the term's own start/end dates, so
        // this has to resolve before the timetable call can go out - unlike
        // the rest, which has no such dependency and still runs in parallel.
        var attDiag: String
        let resolvedTerm: PortalGateway.TermInfo?
        do {
            resolvedTerm = try await PortalGateway.currentTerm(token: token, studentId: identity.studentId)
            attDiag = "term ok"
        } catch {
            resolvedTerm = nil
            attDiag = "term lookup failed: \(error)"
        }

        let timetableRange = Self.timetableRange(for: resolvedTerm)
        async let week = try? PortalGateway.timetable(
            token: token, studentCode: identity.studentId,
            from: timetableRange.from, to: timetableRange.to
        )
        async let photo = Self.fetchPhoto(token: token, identity: identity)
        async let dueResult = Self.fetchDueDates(token: token, identity: identity)

        var rows: [AttRow] = []
        var daywise: [DaySession] = []
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

        let weekResult = await week
        let weekSessions = weekResult?.sessions ?? []
        let faculty = weekResult?.faculty ?? [:]
        var byDay: [String: [Session]] = [:]
        for s in weekSessions {
            guard let d = s.date else { continue }
            byDay[d, default: []].append(s)
        }
        let today = Snapshot.isoDay.string(from: Date())
        let todaySessions = byDay[today] ?? []

        let (due, lmsDiag) = await dueResult
        let (resolvedPhoto, photoDiag) = await photo

        return Portal.Reading(
            rows: rows, sessions: todaySessions, student: identity.name ?? knownStudent,
            // Asked for the whole term, same as `Portal.fetchWeek`'s `whole`
            // case - so the last day actually returned (not just the one
            // asked for) is what claims to be the end of the term, in case
            // the term runs out before `timetableRange.to` does.
            week: byDay, weekDiag: "direct: \(weekSessions.count) sessions in range",
            termEnd: resolvedTerm != nil ? byDay.keys.max() : nil,
            holidays: knownHolidays, daywise: daywise,
            // Settings only has one line for register diagnostics - the photo
            // has no field of its own, so its outcome rides along here rather
            // than failing with no visibility at all, same reasoning as
            // `fetchDueDates`'s diag.
            attDiag: "\(attDiag) | photo: \(photoDiag)",
            photo: resolvedPhoto,
            deadlines: due, lmsDiag: lmsDiag,
            courses: nil, faculty: faculty,
            profile: StudentProfile(
                name: identity.name, email: identity.email, phone: identity.phone,
                campus: identity.campus, program: identity.program,
                studentId: identity.studentId, globalId: identity.globalId
            )
        )
    }

    /// Covers the whole term, the same thing `Portal.fetchWeek`'s API path
    /// gets for free by asking the scheduler for its term feed - except this
    /// has to ask for it explicitly, since `timetable` takes an exact range
    /// rather than "everything you have". Falls back to a plain ±10 days
    /// around today when the term's own dates don't parse, which is strictly
    /// worse than the term but no worse than this endpoint's old hardcoded
    /// window.
    private static func timetableRange(for term: PortalGateway.TermInfo?) -> (from: Date, to: Date) {
        let fallback = (
            from: Date().addingTimeInterval(-10 * 86400),
            to: Date().addingTimeInterval(60 * 86400)
        )
        guard let term,
            let start = Self.parseServerDate(term.termStartDate),
            let end = Self.parseServerDate(term.termEndDate)
        else { return fallback }
        return (start, end)
    }

    /// The dropdown's `TermStartDate`/`TermEndDate` arrive as full ISO
    /// timestamps; tried with and without fractional seconds since which one
    /// the server uses hasn't been pinned down against a live response.
    private static func parseServerDate(_ s: String) -> Date? {
        for withFractional in [true, false] {
            let f = ISO8601DateFormatter()
            f.formatOptions = withFractional
                ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
        }
        return nil
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

    private static func fetchPhoto(
        token: String, identity: PortalGateway.StudentIdentity
    ) async -> (String?, String) {
        guard let p = identity.profilePicture else {
            let keys = identity.profilePictureRawKeys.map { " - real keys: \($0)" } ?? ""
            return (nil, "no ProfilePictureInfo in studentloginbasicinfo" + keys)
        }
        do {
            let data = try await PortalGateway.profilePhoto(
                token: token, containerName: p.containerName,
                blobRelativePath: p.filePath, actualFileName: p.actualFileName
            )
            return ("data:image/jpeg;base64,\(data.base64EncodedString())", "ok, \(data.count) bytes")
        } catch {
            return (nil, "download failed: \(error) (container=\(p.containerName), path=\(p.filePath))")
        }
    }
}
