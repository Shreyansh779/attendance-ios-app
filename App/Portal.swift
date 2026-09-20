import Foundation
import SwiftUI
import WebKit

/// Reads the dashboard out of a real WKWebView.
///
/// The portal has a captcha, so there is no headless path: the webview is put
/// on screen, the login is done by hand, and the same webview is then read with
/// `evaluateJavaScript`. Cookies live in the default persistent data store, so
/// the session survives the sheet closing and usually the captcha is only
/// needed once.
@MainActor
final class Portal: NSObject, ObservableObject {

    static let loginURL = URL(string: "https://myupes-beta.upes.ac.in/")!
    static let dashboardMarker = "/connectportal/user/student/home/dashboard"
    static let weekURL = URL(
        string: "https://myupes-beta.upes.ac.in/connectportal/user/student/curriculum-scheduling"
    )!
    static let holidaysURL = URL(
        string: "https://myupes-beta.upes.ac.in/connectportal/user/student/calendar-events"
    )!
    static let attendanceURL = URL(
        string: "https://myupes-beta.upes.ac.in/connectportal/user/student/student-attendance"
    )!
    static let profileURL = URL(
        string: "https://myupes-beta.upes.ac.in/connectportal/user/student/collaboration/studentprofile"
    )!

    @Published var showingLogin = false
    /// Once the dashboard is reached the login sheet closes and the webview is
    /// re-parented off-screen, so reading continues without holding the UI.
    @Published var hostingHidden = false
    @Published var status: String?
    @Published var busy = false

    /// One webview for the whole app lifetime, so the session is not thrown
    /// away between attempts. Everything - login, dashboard, profile,
    /// timetable - runs through this one: a second webview shares cookies but
    /// not sessionStorage, and the portal's auth handshake can't be assumed to
    /// survive that, whereas navigating this one between routes is already
    /// proven to stay signed in.
    lazy var webView: WKWebView = makeWebView()

    private func makeWebView() -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences = prefs
        cfg.websiteDataStore = .default()
        // The portal has an autoplaying <video> somewhere on the login page.
        // Without this it takes over fullscreen the moment the page loads.
        // Keeping it inline and requiring a tap means it just never plays.
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsPictureInPictureMediaPlayback = false

        // The network recorder goes in as a document-start user script rather
        // than an evaluateJavaScript call, so it is patched in before the
        // page's own JavaScript runs on *every* document. Injecting it after a
        // load is a race the page usually wins - and the request it needs to
        // catch fires during bootstrap.
        cfg.userContentController.addUserScript(
            WKUserScript(
                source: Scrapers.installSpy,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }

    private var pollTask: Task<Void, Never>?
    private var onDone: ((Reading) -> Void)?

    /// One read of the timetable page.
    struct WeekResult {
        var days: [String: [Session]] = [:]
        var diag: String?
        /// True only for the API payload, which carries the whole term. The
        /// DOM agenda never shows more than six days, and six days must not be
        /// mistaken for "that is every class left" - the term maths would then
        /// call a perfectly recoverable subject hopeless.
        var whole = false
    }

    /// One completed read of the portal.
    struct Reading {
        let rows: [AttRow]
        let sessions: [Session]
        let student: String?
        let week: [String: [Session]]
        let weekDiag: String?
        /// Last day of the timetable, when the whole term came through.
        let termEnd: String?
        /// Empty when already known, since the calendar does not change.
        let holidays: [Holiday]
        /// The register, one row per session. Empty when the search page did
        /// not cooperate, which leaves whatever was read last in place.
        let daywise: [DaySession]
        /// `data:image/...;base64,` URI from the dashboard header, if present.
        let photo: String?
    }

    // MARK: - Entry point

    func begin(
        knownStudent: String?,
        knownHolidays: [Holiday] = [],
        onDone: @escaping (Reading) -> Void
    ) {
        // A second tap while a read is in flight used to reload the login page
        // mid-scrape and restart polling, discarding rows that had already
        // settled. busy existed for exactly this and was never consulted.
        guard !busy else { return }
        self.onDone = onDone
        self.student = knownStudent
        self.holidays = knownHolidays
        status = "Log in and solve the captcha. Wait for the dashboard to appear."
        busy = true
        showingLogin = true
        webView.load(URLRequest(url: Portal.loginURL))
        startPolling()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        showingLogin = false
        hostingHidden = false
        busy = false
    }

    // MARK: - Polling

    /// Waits for the router to reach the dashboard, then reads until the row set
    /// stops changing. Plain fixed-interval poll, native Task.sleep — the
    /// settle-on-mutation approach that lived here briefly depended on JS
    /// setTimeout/MutationObserver, which WebKit throttles into never-firing
    /// once the webview is pinned to a 1x1pt frame (see hostingHidden). Native
    /// sleep doesn't care about webview size, so this is the correct
    /// primitive for the hidden-webview phase. 300ms instead of the old
    /// 500ms for a bit more responsiveness without spamming eval calls.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }

            // Logging in is a human step - password, captcha, sometimes an OTP
            // - so it gets a long window. The scrape itself is quick, and the
            // budget restarts once the dashboard is up so a slow login cannot
            // eat it.
            var deadline = Date().addingTimeInterval(300)
            var lastSignature = ""
            var stableReads = 0
            var sawDashboard = false
            var toldStillLoggingIn = false
            var dashboardSeenAt: Date?
            var photo: String?

            while Date() < deadline {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                let path = (((try? await self.eval(Scrapers.route)) ?? nil) as? String) ?? ""
                guard path.contains(Portal.dashboardMarker) else {
                    if !toldStillLoggingIn && !sawDashboard {
                        toldStillLoggingIn = true
                        self.status = "Still on the login page. Solve the captcha and wait for the dashboard."
                    }
                    continue
                }

                if !sawDashboard {
                    sawDashboard = true
                    dashboardSeenAt = Date()
                    deadline = Date().addingTimeInterval(90)
                    self.showingLogin = false
                    self.hostingHidden = true
                    self.status = "Signed in. Reading your classes and attendance."
                }

                let (rows, sessions, cardFound) = await self.readOnce()
                if photo == nil {
                    photo = ((try? await self.eval(Scrapers.photo)) ?? nil) as? String
                }

                let signature = rows.map { "\($0.key):\($0.attended)/\($0.total)" }.joined(separator: ",")
                stableReads = (!rows.isEmpty && signature == lastSignature) ? stableReads + 1 : 0
                lastSignature = signature

                if !rows.isEmpty {
                    self.status = "Found \(rows.count) subjects, \(sessions.count) classes today."
                } else if cardFound {
                    self.status = "Found the attendance card, waiting for it to fill in."
                } else if Date().timeIntervalSince(dashboardSeenAt ?? Date()) > 15 {
                    // Long silence with nothing found yet reads as "broken" -
                    // say plainly that the portal itself is just slow.
                    self.status = "Still reading — the portal's own page can take a while to load."
                }

                // Two identical reads in a row means the cards have settled.
                if !rows.isEmpty && stableReads >= 2 {
                    // Hand over what is already known before going after the
                    // rest. The timetable, the calendar and the profile are
                    // three more page loads, and there is no reason to sit on
                    // a complete set of attendance rows for ten seconds while
                    // they happen. Every field this cannot fill yet is left
                    // empty, and the merge in RootView keeps whatever the last
                    // read established - so a partial can only ever add.
                    self.onDone?(
                        Reading(
                            rows: rows, sessions: sessions, student: self.student,
                            week: [:], weekDiag: nil, termEnd: nil,
                            holidays: [], daywise: [], photo: photo
                        )
                    )

                    // Timetable first, while the app instance the dashboard
                    // bootstrapped is still alive - the weekly scrape soft-routes
                    // within it, and the profile page below is a hard load that
                    // would throw that state away.
                    self.status = "Reading this week's timetable."
                    let week = await self.fetchWeek()

                    // And again, so the timetable is on screen before the
                    // calendar and the profile - two page loads nobody is
                    // waiting on - have even started.
                    self.onDone?(
                        Reading(
                            rows: rows, sessions: sessions, student: self.student,
                            week: week.days, weekDiag: week.diag,
                            termEnd: week.whole ? week.days.keys.max() : nil,
                            holidays: [], daywise: [], photo: photo
                        )
                    )

                    // Both of these are hard loads, so they come after the
                    // timetable, which soft-routes inside the app instance the
                    // dashboard bootstrapped.
                    if self.holidays.isEmpty {
                        self.status = "Reading the holiday calendar."
                        self.holidays = await self.fetchHolidays()
                    }

                    if self.student == nil {
                        self.status = "Getting your name from your profile."
                        self.student = await self.fetchStudentName()
                    }

                    // Last, because it is the slowest thing the app does - one
                    // form submission per subject - and by this point every
                    // screen is already filled in and usable.
                    let span = Portal.registerSpan(week.days.keys.min())
                    self.daywise = await self.fetchDaywise(
                        rows: rows, from: span.from, to: span.to
                    )

                    // The photo is inline in the dashboard header, so it is
                    // read while that page is still the live document.
                    self.finish(
                        rows: rows, sessions: sessions,
                        week: week, photo: photo
                    )
                    return
                }
            }

            self.status = "Gave up waiting for the dashboard. Try again, and make sure it is fully loaded."
            self.hostingHidden = false
            self.busy = false
        }
    }

    private var student: String?
    private var holidays: [Holiday] = []
    private var daywise: [DaySession] = []

    // MARK: - The register

    private struct FieldsPayload: Decodable {
        let ok: Bool
        let courses: [String]
        let hasSearch: Bool
        let diag: String
    }

    private struct GridRow: Decodable {
        let date: String
        let time: String
        let present: Bool
    }

    private struct GridPayload: Decodable {
        let ok: Bool
        let rows: [GridRow]
        let diag: String
    }

    /// The form wants dd-MM-yyyy, which is not what anything else here speaks.
    private static let dmy: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MM-yyyy"
        return f
    }()

    /// The window to ask the register for: from the first day the timetable
    /// knows about to today. Ninety days back if the timetable is empty, which
    /// is a whole semester so far and costs nothing extra to ask for.
    static func registerSpan(_ firstKnownDay: String?) -> (from: String, to: String) {
        let now = Date()
        let start = firstKnownDay.flatMap { Snapshot.isoDay.date(from: $0) }
            ?? Calendar.current.date(byAdding: .day, value: -90, to: now)
            ?? now
        return (dmy.string(from: start), dmy.string(from: now))
    }

    /// One search per subject, because the form takes one course at a time.
    ///
    /// Only subjects the dashboard already counts are asked for: the dropdown
    /// lists everything the programme offers, and a course with no register
    /// costs a page load to learn nothing. A subject that fails is skipped
    /// rather than failing the read - a partial register is worth having.
    private func fetchDaywise(
        rows: [AttRow], from: String, to: String
    ) async -> [DaySession] {
        webView.load(URLRequest(url: Portal.attendanceURL))

        var fields: FieldsPayload?
        for _ in 0..<25 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let raw = ((try? await eval(Scrapers.attFields)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(FieldsPayload.self, from: data),
                p.ok, !p.courses.isEmpty
            else { continue }
            fields = p
            break
        }
        guard let f = fields else { return [] }

        var wanted: [(option: String, key: String)] = []
        for option in f.courses {
            guard let row = matchSubject(option, in: rows), row.total > 0 else { continue }
            if wanted.contains(where: { $0.key == row.key }) { continue }
            wanted.append((option, row.key))
        }
        guard !wanted.isEmpty else { return [] }

        var out: [DaySession] = []
        for (i, w) in wanted.enumerated() {
            if Task.isCancelled { break }
            status = "Reading the register, \(i + 1) of \(wanted.count)."

            let req = ["course": w.option, "from": from, "to": to]
            guard let body = try? JSONEncoder().encode(req),
                let js = String(data: body, encoding: .utf8)
            else { continue }

            _ = try? await eval("window.__attReq = \(js); true")
            _ = try? await eval(Scrapers.attRun)

            for _ in 0..<20 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let raw = ((try? await eval(Scrapers.attGrid)) ?? nil) as? String,
                    let data = raw.data(using: .utf8),
                    let g = try? JSONDecoder().decode(GridPayload.self, from: data),
                    g.ok
                else { continue }
                out.append(
                    contentsOf: g.rows.map {
                        DaySession(subject: w.key, date: $0.date, time: $0.time, present: $0.present)
                    }
                )
                break
            }
        }
        return out
    }

    private struct HolidayPayload: Decodable {
        let ok: Bool
        let holidays: [Holiday]
    }

    /// The academic calendar. Fetched only when we do not already have it -
    /// the holiday list for a year is fixed, and this is a whole extra page
    /// load on a connection that has already done several.
    private func fetchHolidays() async -> [Holiday] {
        webView.load(URLRequest(url: Portal.holidaysURL))
        for _ in 0..<25 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let raw = ((try? await eval(Scrapers.holidays)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(HolidayPayload.self, from: data),
                p.ok, !p.holidays.isEmpty
            else { continue }
            return p.holidays
        }
        return []
    }

    private struct NamePayload: Decodable {
        let ok: Bool
        let name: String?
    }

    /// Navigates to the profile page and waits for the name to appear. Safe to
    /// leave the dashboard by this point: its data is already captured.
    private func fetchStudentName() async -> String? {
        webView.load(URLRequest(url: Portal.profileURL))
        for _ in 0..<25 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let raw = ((try? await eval(Scrapers.student)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(NamePayload.self, from: data),
                p.ok,
                let name = p.name,
                !name.isEmpty
            else { continue }
            return name
        }
        return nil
    }

    private struct WeekPayload: Decodable {
        let ok: Bool
        let sessions: [Session]
        let diag: String?
        let tasks: Int?
        let view: String?
        /// Raw entry count in the payload. The dashboard calls the same
        /// endpoint for its own one-day card, so size is what separates the
        /// real term feed from that.
        let items: Int?
    }

    /// The agenda page, grouped by date. Failing here is not fatal — the
    /// dashboard card already covers today.
    ///
    /// Two things have to happen before a read is worth anything: the
    /// scheduler has to be in Agenda view (it doesn't open there, and no other
    /// view renders the date-column table), and its rows have to have finished
    /// composing. So this switches the view first, then requires two identical
    /// non-empty reads before believing the result.
    private func fetchWeek() async -> WeekResult {
        var lastDiag: String?
        // Kept separately so the DOM scrape's diagnostic can't overwrite it -
        // the API path is the one that matters, and losing its message is what
        // hid a field-name mismatch last time.
        var apiDiag: String?
        /// Widest set of days seen so far, kept because the first payload the
        /// page makes available is often only today.
        var bestWeek: WeekResult?
        let began = Date()
        var lastSignature = ""
        var stableReads = 0
        var inAgenda = false
        var hardLoaded = false
        var nudged = false
        var softNavAt: Date?
        var agendaAt: Date?

        // In-app routing first; a hard load is the fallback if the router
        // doesn't take us there.
        let nav = ((try? await eval(Scrapers.gotoWeek)) ?? nil) as? String
        lastDiag = "nav=\(nav ?? "nil")"
        softNavAt = Date()

        for _ in 0..<70 {  // 70 * 500ms = 35s
            if Task.isCancelled { return WeekResult(diag: lastDiag) }
            try? await Task.sleep(nanoseconds: 500_000_000)

            // The API payload is the real source of truth: the page fetches
            // the whole timetable as JSON and then renders none of it, so this
            // succeeds long before (and more often than) any DOM scrape.
            if let raw = ((try? await eval(Scrapers.weekApi)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(WeekPayload.self, from: data)
            {
                apiDiag = p.diag
                if p.ok {
                    var byDay: [String: [Session]] = [:]
                    for s in p.sessions {
                        guard let d = s.date else { continue }
                        byDay[d, default: []].append(s)
                    }
                    if byDay.count > (bestWeek?.days.count ?? 0) {
                        // Fifty-odd entries means the scheduler's term feed;
                        // the dashboard's own call to this endpoint returns a
                        // handful. Only the former may claim to be the term.
                        bestWeek = WeekResult(
                            days: byDay, diag: p.diag, whole: (p.items ?? 0) >= 50
                        )
                    }
                    // The dashboard calls the same endpoint for its "today"
                    // card, so the first payload available is often a single
                    // day. More than one day means this is the real term
                    // timetable, and there is nothing better to wait for.
                    if let best = bestWeek, best.days.count >= 2 { return best }
                }
            }

            // Don't wait out the whole budget for a fuller payload that may
            // never come - one day is still better than nothing.
            if let best = bestWeek, Date().timeIntervalSince(began) > 12 {
                return best
            }

            let path = (((try? await eval(Scrapers.route)) ?? nil) as? String) ?? ""

            // Soft nav didn't land within a few seconds - do it the blunt way.
            if !path.contains("curriculum-scheduling") {
                if !hardLoaded, Date().timeIntervalSince(softNavAt ?? Date()) > 4 {
                    hardLoaded = true
                    lastDiag = "nav=hard-load"
                    webView.load(URLRequest(url: Portal.weekURL))
                }
                continue
            }

            // Keep asking until it takes: the scheduler isn't mounted for the
            // first second or so, and switching view re-renders the table.
            if !inAgenda {
                let r = ((try? await eval(Scrapers.agenda)) ?? nil) as? String
                switch r {
                case "already":
                    inAgenda = true
                    agendaAt = Date()
                case "select", "button":
                    // Give Angular a beat to swap the view in, then confirm on
                    // the next pass rather than trusting the click.
                    lastDiag = "agenda=switched(\(r ?? ""))"
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                case "no-scheduler":
                    lastDiag = "agenda=no-scheduler"
                    continue
                default:
                    // "not-found" or a JS error: the picker isn't where it was.
                    // Read anyway - the page may already be showing a table.
                    inAgenda = true
                    agendaAt = Date()
                    lastDiag = "agenda=\(r ?? "nil")"
                }
            }

            guard let raw = ((try? await eval(Scrapers.week)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(WeekPayload.self, from: data)
            else { continue }
            lastDiag = p.diag

            // Agenda is up but empty: the initial event query may never have
            // fired. Ask the scheduler to re-query its own date range once.
            if (p.tasks ?? 0) == 0, !nudged,
                Date().timeIntervalSince(agendaAt ?? Date()) > 6
            {
                nudged = true
                let n = ((try? await eval(Scrapers.nudge)) ?? nil) as? String
                lastDiag = (p.diag ?? "") + " nudge=\(n ?? "nil")"
                continue
            }

            guard p.ok else { stableReads = 0; continue }

            let signature = p.sessions.map { "\($0.date ?? ""):\($0.subject):\($0.start)" }
                .sorted().joined(separator: ",")
            stableReads = signature == lastSignature ? stableReads + 1 : 0
            lastSignature = signature
            guard stableReads >= 2 else { continue }

            var byDay: [String: [Session]] = [:]
            for s in p.sessions {
                guard let d = s.date else { continue }
                byDay[d, default: []].append(s)
            }
            if !byDay.isEmpty { return WeekResult(days: byDay, diag: p.diag) }
        }

        // Nothing worked. Report what the page actually asked the server for -
        // that distinguishes "no request was ever made" from "the request came
        // back empty" from "the request was rejected".
        if let best = bestWeek { return best }

        let spy = ((try? await eval(Scrapers.spyDump)) ?? nil) as? String
        return WeekResult(diag: [apiDiag, lastDiag, spy].compactMap { $0 }.joined(separator: " || "))
    }

    /// The last word. Everything it carries has already been handed over once
    /// as a partial, except the timetable, the calendar and the name.
    private func finish(
        rows: [AttRow], sessions: [Session],
        week: WeekResult, photo: String?
    ) {
        pollTask?.cancel()
        pollTask = nil
        showingLogin = false
        hostingHidden = false
        busy = false
        status = nil
        onDone?(
            Reading(
                rows: rows, sessions: sessions, student: student,
                week: week.days, weekDiag: week.diag,
                termEnd: week.whole ? week.days.keys.max() : nil,
                holidays: holidays,
                daywise: daywise,
                photo: photo
            )
        )
    }

    // MARK: - Reading

    private struct AttPayload: Decodable {
        let ok: Bool
        let rows: [AttRow]
        let cardFound: Bool?
    }

    private struct SesPayload: Decodable {
        let ok: Bool
        let sessions: [Session]
    }

    private func readOnce() async -> ([AttRow], [Session], Bool) {
        // Both scrapers hit the same document; issuing them concurrently
        // instead of one-after-another cuts the round-trip cost of each tick
        // roughly in half.
        async let attRaw = (try? await eval(Scrapers.attendance)) ?? nil
        async let sesRaw = (try? await eval(Scrapers.sessions)) ?? nil

        var rows: [AttRow] = []
        var cardFound = false
        if let raw = (await attRaw) as? String,
            let data = raw.data(using: .utf8),
            let p = try? JSONDecoder().decode(AttPayload.self, from: data)
        {
            rows = p.rows
            cardFound = p.cardFound ?? false
        }

        var sessions: [Session] = []
        if let raw = (await sesRaw) as? String,
            let data = raw.data(using: .utf8),
            let p = try? JSONDecoder().decode(SesPayload.self, from: data)
        {
            sessions = p.sessions
        }

        return (rows, sessions, cardFound)
    }

    private func eval(_ js: String, in target: WKWebView? = nil) async throws -> Any? {
        let wv = target ?? webView
        return try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(js) { value, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: value) }
            }
        }
    }
}

extension Portal: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // -999 is what WebKit reports whenever one load interrupts another,
        // which this class does on purpose twice per read: the timetable hard
        // load and the profile load. Not a failure worth showing.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let msg = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.status = "Could not reach the portal: \(msg)"
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let msg = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.status = "Page failed to load: \(msg)"
        }
    }
}

/// Puts the live webview on screen without recreating it.
struct PortalWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
