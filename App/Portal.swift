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
    /// away between attempts.
    lazy var webView: WKWebView = {
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

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }()

    private var pollTask: Task<Void, Never>?
    private var onDone: (([AttRow], [Session], String?, [String: [Session]], String?) -> Void)?

    // MARK: - Entry point

    func begin(
        knownStudent: String?,
        onDone: @escaping ([AttRow], [Session], String?, [String: [Session]], String?) -> Void
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
                    if self.student == nil {
                        self.status = "Getting your name from your profile."
                        self.student = await self.fetchStudentName()
                    }

                    self.status = "Reading this week's timetable."
                    let (week, diag) = await self.fetchWeek()

                    self.finish(rows: rows, sessions: sessions, week: week, diag: diag)
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
    }

    /// The agenda page, grouped by date. Failing here is not fatal — the
    /// dashboard card already covers today.
    ///
    /// The Kendo scheduler's Agenda view composes its rows asynchronously and
    /// can render just the header table before the actual row content fills
    /// in. A single non-empty read isn't proof it's done — this requires two
    /// identical non-empty reads in a row, same as the dashboard cards.
    private func fetchWeek() async -> ([String: [Session]], String?) {
        webView.load(URLRequest(url: Portal.weekURL))
        var lastDiag: String?
        var lastSignature = ""
        var stableReads = 0

        for _ in 0..<50 {  // 50 * 700ms = 35s
            if Task.isCancelled { return ([:], lastDiag) }
            try? await Task.sleep(nanoseconds: 700_000_000)

            guard let raw = ((try? await eval(Scrapers.week)) ?? nil) as? String,
                let data = raw.data(using: .utf8),
                let p = try? JSONDecoder().decode(WeekPayload.self, from: data)
            else { continue }
            lastDiag = p.diag
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
        return ([:], lastDiag)
    }

    private func finish(
        rows: [AttRow], sessions: [Session],
        week: [String: [Session]], diag: String?
    ) {
        pollTask?.cancel()
        pollTask = nil
        showingLogin = false
        hostingHidden = false
        busy = false
        status = nil
        onDone?(rows, sessions, student, week, diag)
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

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(js) { value, error in
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
