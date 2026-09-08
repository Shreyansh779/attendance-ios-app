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

    /// One completed read of the portal.
    struct Reading {
        let rows: [AttRow]
        let sessions: [Session]
        let student: String?
        let week: [String: [Session]]
        let weekDiag: String?
        /// `data:image/...;base64,` URI from the dashboard header, if present.
        let photo: String?
    }

    // MARK: - Entry point

    func begin(
        knownStudent: String?,
        onDone: @escaping (Reading) -> Void
    ) {
        self.onDone = onDone
        self.student = knownStudent
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

            let deadline = Date().addingTimeInterval(90)
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
                    // Timetable first, while the app instance the dashboard
                    // bootstrapped is still alive - the weekly scrape soft-routes
                    // within it, and the profile page below is a hard load that
                    // would throw that state away.
                    self.status = "Reading this week's timetable."
                    let (week, diag) = await self.fetchWeek()

                    if self.student == nil {
                        self.status = "Getting your name from your profile."
                        self.student = await self.fetchStudentName()
                    }

                    // The photo is inline in the dashboard header, so it is
                    // read while that page is still the live document.
                    self.finish(
                        rows: rows, sessions: sessions,
                        week: week, diag: diag, photo: photo
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
    }

    /// The agenda page, grouped by date. Failing here is not fatal — the
    /// dashboard card already covers today.
    ///
    /// Two things have to happen before a read is worth anything: the
    /// scheduler has to be in Agenda view (it doesn't open there, and no other
    /// view renders the date-column table), and its rows have to have finished
    /// composing. So this switches the view first, then requires two identical
    /// non-empty reads before believing the result.
    private func fetchWeek() async -> ([String: [Session]], String?) {
        var lastDiag: String?
        // Kept separately so the DOM scrape's diagnostic can't overwrite it -
        // the API path is the one that matters, and losing its message is what
        // hid a field-name mismatch last time.
        var apiDiag: String?
        /// Widest set of days seen so far, kept because the first payload the
        /// page makes available is often only today.
        var bestWeek: ([String: [Session]], String?)?
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
            if Task.isCancelled { return ([:], lastDiag) }
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
                    if byDay.count > (bestWeek?.0.count ?? 0) {
                        bestWeek = (byDay, p.diag)
                    }
                    // The dashboard calls the same endpoint for its "today"
                    // card, so the first payload available is often a single
                    // day. More than one day means this is the real term
                    // timetable, and there is nothing better to wait for.
                    if let best = bestWeek, best.0.count >= 2 { return best }
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
            if !byDay.isEmpty { return (byDay, p.diag) }
        }

        // Nothing worked. Report what the page actually asked the server for -
        // that distinguishes "no request was ever made" from "the request came
        // back empty" from "the request was rejected".
        if let best = bestWeek { return best }

        let spy = ((try? await eval(Scrapers.spyDump)) ?? nil) as? String
        return ([:], [apiDiag, lastDiag, spy].compactMap { $0 }.joined(separator: " || "))
    }

    private func finish(
        rows: [AttRow], sessions: [Session],
        week: [String: [Session]], diag: String?, photo: String?
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
                week: week, weekDiag: diag, photo: photo
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
