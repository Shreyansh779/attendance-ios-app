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

    static let dashboardMarker = "/connectportal/user/student/home/dashboard"
    /// Where a refresh starts.
    ///
    /// Not the site root. With a live session the root redirects to
    /// /oneportal/app/auth/login and parks there for good - it will not carry
    /// you back into the portal on its own, so every refresh began by asking
    /// for a password that was not needed. This URL resumes the session
    /// silently, and only bounces to the login page when there is genuinely
    /// nobody signed in.
    static let dashboardURL = URL(
        string: "https://myupes-beta.upes.ac.in/connectportal/user/student/home/dashboard"
    )!
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
    /// Whether one LMS link is being shown in its own cover, over the live
    /// webview - which is the only place the Moodle session exists.
    @Published var showingVisit = false
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
        // No scheme forced here. Overriding to light to keep the portal
        // rendering the way it always had also turned the keyboard light,
        // because the keyboard takes its appearance from the traits of the
        // view that raised it - and a light keyboard under a dark app is more
        // jarring, every time you log in, than the portal being dark once.
        return wv
    }

    private var pollTask: Task<Void, Never>?
    private var onDone: ((Reading) -> Void)?

    /// One read of the timetable page.
    struct WeekResult {
        var days: [String: [Session]] = [:]
        var diag: String?
        /// Subject to the teachers who take your classes.
        var teachers: [String: [String]] = [:]
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
        /// What that search did, for when it produced nothing.
        let attDiag: String?
        /// `data:image/...;base64,` URI from the dashboard header, if present.
        let photo: String?
        /// Coursework the LMS is waiting on.
        ///
        /// nil when the read did not run or did not work, which leaves
        /// whatever was read last in place. Empty is a real answer - nothing
        /// of yours is due - and has to replace the last read, which is
        /// exactly what an `isEmpty` check in the merge could not express.
        let deadlines: [Deadline]?
        /// What the LMS read did, for when it produced nothing.
        let lmsDiag: String?
        /// This semester's courses and their material. Same visit, same page.
        /// nil, not empty, when the read did not happen.
        let courses: [LmsCourse]?
        /// Subject to the teachers who take your classes.
        let faculty: [String: [String]]
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
        registerTask?.cancel()
        self.onDone = onDone
        self.student = knownStudent
        self.holidays = knownHolidays
        status = "Opening the portal."
        busy = true
        // Held back deliberately: with a session still good this never has to
        // appear at all, and putting a login form in front of somebody who is
        // already signed in is what made every first refresh fail.
        showingLogin = false
        showingVisit = false
        // Hosted from the first instant, not from the moment the dashboard is
        // reached. A WKWebView that is not in a window gets its timers
        // throttled to nothing, so the page it was told to load can sit half
        // finished - and the only reason it used to be in the window this
        // early was that the login cover was holding it. Now that the cover is
        // held back, this has to do it: full size, under an opaque backdrop,
        // so the portal renders as if on screen and is never seen.
        hostingHidden = true
        webView.load(URLRequest(url: Portal.dashboardURL))
        startPolling()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        registerTask?.cancel()
        registerTask = nil
        visitTask?.cancel()
        visitTask = nil
        showingVisit = false
        showingLogin = false
        hostingHidden = false
        busy = false
    }

    /// Close the link cover without touching a read that may be running.
    func endVisit() {
        visitTask?.cancel()
        visitTask = nil
        showingVisit = false
        status = nil
    }

    /// The document on screen, as a file on disk, so the share sheet has
    /// something real to hand to Files, Mail or anything else.
    ///
    /// Sharing the URL instead would be useless: a Moodle `pluginfile.php`
    /// link outside this webview lands on a login form, so whatever received
    /// it would get a page about signing in. The bytes have to travel, which
    /// means fetching them again with this webview's cookies.
    func downloadVisible() async -> URL? {
        guard let url = webView.url else { return nil }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { k in
            store.getAllCookies { k.resume(returning: $0) }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cookies.forEach { cfg.httpCookieStorage?.setCookie($0) }
        cfg.httpShouldSetCookies = true

        guard let (tmp, response) = try? await URLSession(configuration: cfg).download(from: url)
        else { return nil }

        // The server's own name for it where there is one - a pluginfile path
        // ends in the filename, but percent-escaped, and Moodle does not
        // always say. Anything without an extension confuses every receiver,
        // so it gets one.
        var name = response.suggestedFilename
            ?? url.lastPathComponent.removingPercentEncoding
            ?? url.lastPathComponent
        if name.isEmpty || !name.contains(".") { name = (name.isEmpty ? "document" : name) + ".pdf" }

        // Its own directory, so two files of the same name from two courses
        // do not overwrite each other mid-share.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared/\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }

        let dest = dir.appendingPathComponent(name)
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return nil }
        return dest
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
            var sawLogin = false
            var nudgedBack = false
            var toldStillLoggingIn = false
            var dashboardSeenAt: Date?
            var photo: String?

            while Date() < deadline {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                let path = (((try? await self.eval(Scrapers.route)) ?? nil) as? String) ?? ""
                guard path.contains(Portal.dashboardMarker) else {
                    if path.contains("auth/login") {
                        // Genuinely signed out, so now the sheet is worth
                        // showing.
                        sawLogin = true
                        nudgedBack = false
                        if !self.showingLogin { self.showingLogin = true }
                        if !toldStillLoggingIn {
                            toldStillLoggingIn = true
                            self.status = "Log in and solve the captcha. Wait for the dashboard to appear."
                        }
                    } else if sawLogin && !nudgedBack {
                        // Signing in lands on whatever the portal feels like,
                        // which is not always the dashboard. Ask for it once.
                        nudgedBack = true
                        self.status = "Signed in. Opening your dashboard."
                        self.webView.load(URLRequest(url: Portal.dashboardURL))
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
                            holidays: [], daywise: [], attDiag: nil, photo: photo,
                            deadlines: nil, lmsDiag: nil, courses: nil, faculty: [:]
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
                            holidays: [], daywise: [], attDiag: nil, photo: photo,
                            deadlines: nil, lmsDiag: nil, courses: nil, faculty: week.teachers
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

                    // The photo is inline in the dashboard header, so it is
                    // read while that page is still the live document.
                    self.finish(
                        rows: rows, sessions: sessions,
                        week: week, photo: photo
                    )

                    // The register goes after the read finishes, not inside
                    // it. One form submission per subject is the slowest thing
                    // this app does, and while it was on the critical path a
                    // portal that would not cooperate with it held `busy` and
                    // the status banner hostage - a read that had in fact
                    // succeeded looked like one that had hung.
                    self.startRegister(rows: rows)
                    return
                }
            }

            // Which half of the wait ran out matters: one means the login
            // never completed, the other means the dashboard's own cards never
            // filled in. They are different problems with different fixes.
            self.status = sawDashboard
                ? "The dashboard loaded but its attendance card never filled in. Try again."
                : "Gave up waiting for the dashboard. Log in, wait for it to finish loading, then try again."
            self.hostingHidden = false
            self.busy = false
        }
    }

    private var student: String?
    private var holidays: [Holiday] = []
    private var daywise: [DaySession] = []
    private var attDiag: String?
    private var deadlines: [Deadline]?
    private var lmsDiag: String?
    private var courses: [LmsCourse]?
    private var faculty: [String: [String]] = [:]

    // MARK: - The register

    /// Every diagnostic carries the time it was written: one that is only
    /// written on failure is indistinguishable from one left over from the
    /// run before, which is exactly the confusion it caused.
    private func stamped(_ lines: [String]) -> String {
        Portal.stamp.string(from: Date()) + String(UnicodeScalar(10))
            + lines.joined(separator: String(UnicodeScalar(10)))
    }

    /// So a diagnostic says which run it came from.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private struct StepPayload: Decodable {
        let ok: Bool
        let diag: String
    }

    private struct RegisterRow: Decodable {
        let subject: String
        let date: String
        let time: String
        let present: Bool
    }

    private struct RegisterPayload: Decodable {
        let done: Bool
        let ok: Bool
        let rows: [RegisterRow]
        let diag: String
    }

    private func decode<T: Decodable>(_ type: T.Type, _ blob: String) async -> T? {
        guard let raw = ((try? await eval(blob)) ?? nil) as? String,
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The register, in one request.
    ///
    /// Four builds went into driving the search form by hand - three Kendo
    /// dropdowns, two date fields, a Search button, a results grid - and none
    /// of it could ever have worked: the date inputs are `readonly`, so only
    /// the calendar popup can set them, and the grid is two tables with the
    /// headers in one and the rows in the other.
    ///
    /// The page itself is talking to an endpoint that takes a list of courses
    /// and answers with JSON. So this asks that endpoint the same question,
    /// for every course at once, and parses the reply. The form is not
    /// touched at all.
    private func fetchDaywise(rows: [AttRow]) async -> [DaySession] {
        webView.load(URLRequest(url: Portal.attendanceURL))

        var note: [String] = []
        var started = false
        for _ in 0..<24 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let s = await decode(StepPayload.self, Scrapers.registerStart) else { continue }
            note = [s.diag]
            if s.ok { started = true; break }
        }
        guard started else {
            attDiag = stamped(["the page never produced a session"] + note)
            return []
        }

        for _ in 0..<40 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let p = await decode(RegisterPayload.self, Scrapers.registerRead), p.done else { continue }
            note.append(p.diag)
            guard p.ok else { break }

            // The portal names a course, the dashboard names a subject, and
            // they are not always the same string.
            var out: [DaySession] = []
            var unmatched = Set<String>()
            for row in p.rows {
                guard let hit = matchSubject(row.subject, in: rows) else {
                    unmatched.insert(row.subject)
                    continue
                }
                out.append(
                    DaySession(subject: hit.key, date: row.date, time: row.time, present: row.present)
                )
            }
            if !unmatched.isEmpty {
                note.append("no subject for: " + unmatched.sorted().prefix(4).joined(separator: ", "))
            }
            attDiag = stamped(note)
            return out
        }

        attDiag = stamped(["no answer from the register"] + note)
        return []
    }


    private struct KeyPayload: Decodable {
        let done: Bool
        let ok: Bool
        let url: String
        let diag: String
    }

    private struct DuePayload: Decodable {
        let done: Bool
        let ok: Bool
        let items: [Deadline]
        let diag: String
    }

    /// Everything the LMS is waiting on.
    ///
    /// Two origins, so two halves. The key is issued by the portal and is good
    /// for one use, so it is asked for while the portal is still the live
    /// document; then the webview follows it to Moodle, which answers the rest
    /// from its own AJAX endpoint.
    private func fetchDeadlines() async -> [Deadline]? {
        let (target, note) = await askForKey(seconds: 8)
        guard let target else {
            lmsDiag = stamped(["no key for the lms", note])
            return nil
        }

        webView.load(URLRequest(url: target))
        var lastDue = "no reply from the page"
        for _ in 0..<30 {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let p = await decode(DuePayload.self, Scrapers.lmsDue) else { continue }
            lastDue = p.diag
            guard p.done else { continue }
            lmsDiag = stamped([note, p.diag])
            guard p.ok else { return nil }
            return p.items.sorted { $0.due < $1.due }
        }

        lmsDiag = stamped(["no answer from the lms", note, lastDue])
        return nil
    }

    /// Ask the portal for a Moodle login URL. Good for exactly one use.
    ///
    /// Must be called while a portal page is the live document - the token it
    /// needs lives in that origin's localStorage.
    private func askForKey(seconds: Double) async -> (URL?, String) {
        var note = "no reply from the portal"
        // Every call wants a fresh key. The portal stays one Angular document
        // across signing in, so a failure `lmsKey` parked before the login -
        // a stale token answered 401 - was still there after it, handed back
        // on the first poll, and the link never opened.
        _ = try? await eval("delete window.__lmsk; 1")
        for _ in 0..<Int(seconds / 0.4) {
            if Task.isCancelled { return (nil, "cancelled") }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let k = await decode(KeyPayload.self, Scrapers.lmsKey) else { continue }
            note = k.diag
            guard k.done else { continue }
            return (k.ok ? URL(string: k.url) : nil, k.diag)
        }
        return (nil, note)
    }

    /// Wait for the webview's path to satisfy `match`.
    private func waitForRoute(
        _ seconds: Double, _ match: @escaping (String) -> Bool
    ) async -> Bool {
        for _ in 0..<Int(seconds / 0.4) {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let path = (((try? await eval(Scrapers.route)) ?? nil) as? String) ?? ""
            if match(path) { return true }
        }
        return false
    }

    /// Drop the deadlines that are not yours.
    ///
    /// The calendar feed the deadlines come from knows nothing about sections,
    /// so it hands over every assignment in every course you are enrolled in -
    /// including the nineteen other teachers' ones. The course scrape has
    /// already worked out which material is yours, and both name the same
    /// module by the same URL, so that answer is reused here rather than
    /// worked out twice.
    ///
    /// An empty course list means the scrape failed, not that nothing is
    /// yours, so in that case everything stays.
    static func mine(_ due: [Deadline]?, in courses: [LmsCourse]?) -> [Deadline]? {
        guard let due else { return nil }
        let known = Set((courses ?? []).flatMap { $0.items.map(\.url) })
        guard !known.isEmpty else { return due }
        return due.filter { known.contains($0.url) }
    }

    private struct CoursePayload: Decodable {
        let done: Bool
        let ok: Bool
        let courses: [LmsCourse]
        let diag: String
    }

    /// This semester's courses and their material, off the page fetchDeadlines
    /// is already sitting on. No second login, no second navigation.
    private func fetchCourses(faculty: [String: [String]]) async -> [LmsCourse]? {
        // Handed over rather than fetched: the timetable is on the portal's
        // origin and this runs on Moodle's, so there is no way for the blob to
        // go and get it. Set on every pass, because the first passes land on
        // the documents of a redirect chain and none of them keep it.
        let mine = (try? JSONEncoder().encode(faculty))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var last = "no reply from the page"
        // Sixty, not thirty: the blob opens each Folder module's own page one
        // at a time, up to the cap in `lmsCourses`, and a page apiece on a
        // phone is a second or two of work the two API calls never were.
        // Giving up early does not lose the list - the merge keeps the last
        // one - but it means the tab never updates again, and on a first run
        // it stays empty while the work was about to finish.
        for _ in 0..<60 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = try? await eval("window.__mine = \(mine); 1")
            guard let p = await decode(CoursePayload.self, Scrapers.lmsCourses) else { continue }
            last = p.diag
            guard p.done else { continue }
            lmsDiag = stamped([lmsDiag ?? "", p.diag].filter { !$0.isEmpty })
            return p.ok ? p.courses : nil
        }
        lmsDiag = stamped(["no course list from the lms", last])
        return nil
    }

    // MARK: - Opening one link

    private var visitTask: Task<Void, Never>?

    /// Open one LMS link, signing in on the way if that is what it takes.
    ///
    /// The link only works inside this webview, because this webview is the
    /// only place the Moodle session lives - a link handed to Safari lands on
    /// a login form Moodle will not let anyone past. So the cover shows this
    /// webview, and if the session has lapsed it is rebuilt underneath: a
    /// fresh key from the portal, or, when the portal itself has signed out,
    /// the portal's own login page followed by the link.
    /// What the cover is showing, for its title. The file's own name says more
    /// than "LMS" does when the thing on screen is a PDF.
    @Published var visitTitle: String?

    func visit(_ url: URL) {
        // A read in flight is driving this same webview, so it has to stop
        // rather than fight over where the page goes.
        registerTask?.cancel()
        visitTask?.cancel()
        // `lastPathComponent` is already percent-decoded. Decoding it a second
        // time returns nil for any name carrying a literal % - "50% off.pdf"
        // reads as a broken escape - and nil fell back to "LMS".
        let name = url.deletingPathExtension().lastPathComponent
        visitTitle = name.isEmpty ? nil : name
        showingVisit = true
        status = nil
        hostingHidden = false
        webView.load(URLRequest(url: url))

        visitTask = Task { [weak self] in
            guard let self else { return }

            // Moodle's session normally outlives the last refresh, so the link
            // is tried first and the rest only happens when it bounces.
            let bounced = await self.waitForRoute(8) { $0.contains("/login/index.php") }
            if Task.isCancelled { return }
            guard bounced else {
                self.status = nil
                return
            }

            self.status = "Signing you in to the LMS."
            self.webView.load(URLRequest(url: Portal.dashboardURL))
            var (key, note) = await self.askForKey(seconds: 8)
            if Task.isCancelled { return }

            if key == nil {
                // The portal has signed out too, so there is a person in the
                // loop. The cover is already showing this webview, so the
                // login page simply appears in it.
                self.status = "Log in and solve the captcha — this opens straight after."
                // Signing in lands on whatever the portal feels like, which is
                // often not the dashboard - so it is asked for, repeatedly,
                // until it arrives.
                //
                // Never phrased as "wait until the route is not the login
                // page": `eval` returns "" whenever it cannot read the page,
                // and "" is not the login page either, so that test passes on
                // the first tick before anybody has typed anything.
                var inAgain = false
                for _ in 0..<60 {
                    if Task.isCancelled { return }
                    if await self.waitForRoute(5, { $0.contains(Portal.dashboardMarker) }) {
                        inAgain = true
                        break
                    }
                    let path = (((try? await self.eval(Scrapers.route)) ?? nil) as? String) ?? ""
                    if !path.isEmpty, !path.contains("auth/login") {
                        self.webView.load(URLRequest(url: Portal.dashboardURL))
                    }
                }
                if Task.isCancelled { return }
                guard inAgain else {
                    self.status = "Gave up waiting for the portal."
                    return
                }
                self.status = "Signing you in to the LMS."
                (key, note) = await self.askForKey(seconds: 10)
                if Task.isCancelled { return }
            }

            guard let key else {
                self.status = "Could not sign in to the LMS — \(note)"
                return
            }

            // The key lands on Moodle's own home page, so the link is a second
            // hop. wantsurl is not relied on: one extra load is cheaper than a
            // parameter this portal's Moodle may or may not honour.
            self.webView.load(URLRequest(url: key))
            _ = await self.waitForRoute(12) { !$0.contains("/auth/userkey/") }
            if Task.isCancelled { return }
            self.status = nil
            self.webView.load(URLRequest(url: url))
        }
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
        /// Subject to the teachers who take your classes. The LMS needs it to
        /// tell your own teacher's sections from the other nineteen's.
        let teachers: [String: [String]]?
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
                            days: byDay, diag: p.diag, teachers: p.teachers ?? [:],
                            whole: (p.items ?? 0) >= 50
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
        faculty = week.teachers
        pollTask?.cancel()
        pollTask = nil
        showingLogin = false
        busy = false
        status = nil
        let reading = Reading(
            rows: rows, sessions: sessions, student: student,
            week: week.days, weekDiag: week.diag,
            termEnd: week.whole ? week.days.keys.max() : nil,
            holidays: holidays,
            daywise: daywise,
            attDiag: attDiag,
            photo: photo,
            deadlines: deadlines,
            lmsDiag: lmsDiag,
            courses: courses,
            faculty: faculty
        )
        last = reading
        onDone?(reading)
    }

    /// The last complete read, so the register can hand the same thing back
    /// with its own findings added rather than with everything else blank.
    private var last: Reading?
    private var registerTask: Task<Void, Never>?

    /// Read the register in the background, after the app is already usable.
    ///
    /// `busy` is already false by the time this runs, so the refresh control
    /// works and nothing waits on it. A second refresh cancels it, because the
    /// read it would be adding to has been replaced.
    private func startRegister(rows: [AttRow]) {
        registerTask?.cancel()
        registerTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.fetchDaywise(rows: rows)
            if Task.isCancelled { return }
            self.daywise = found

            // The LMS is a different site, so this is the last thing done -
            // getting there means spending a one-shot key and leaving the
            // portal's origin behind.
            self.status = "Checking the LMS."
            let all = await self.fetchDeadlines()
            if Task.isCancelled { return }
            // Same Moodle page, so this costs a request rather than a login.
            let stocked = await self.fetchCourses(faculty: self.faculty)
            if Task.isCancelled { return }
            self.courses = stocked
            let due = Portal.mine(all, in: stocked)
            self.deadlines = due
            self.status = nil
            self.hostingHidden = false
            guard let base = self.last else { return }
            self.onDone?(
                Reading(
                    rows: base.rows, sessions: base.sessions, student: base.student,
                    week: base.week, weekDiag: base.weekDiag, termEnd: base.termEnd,
                    holidays: base.holidays,
                    daywise: found,
                    attDiag: self.attDiag,
                    photo: base.photo,
                    deadlines: due,
                    lmsDiag: self.lmsDiag,
                    courses: self.courses,
                    faculty: self.faculty
                )
            )
        }
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
    /// A tap on a file inside a Moodle page, sent back through `visit`.
    ///
    /// Moodle links an assignment's attachments with `forcedownload=1`, and a
    /// WKWebView answers a download by doing nothing at all, so the tap went
    /// nowhere. Without the flag the same URL is served inline. A link asking
    /// for a new window gets nothing either - there is no UI delegate to make
    /// one - so it opens here instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard showingVisit, let url = navigationAction.request.url else { return .allow }
        if navigationAction.navigationType == .linkActivated,
            url.path.contains("/pluginfile.php/"),
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            let kept = (parts.queryItems ?? []).filter { $0.name != "forcedownload" }
            parts.queryItems = kept.isEmpty ? nil : kept
            visit(parts.url ?? url)
            return .cancel
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            return .cancel
        }
        return .allow
    }

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
