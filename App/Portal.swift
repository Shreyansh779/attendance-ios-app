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

    @Published var showingLogin = false
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

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }()

    private var pollTask: Task<Void, Never>?
    private var onDone: (([AttRow], [Session], String?) -> Void)?

    // MARK: - Entry point

    func begin(onDone: @escaping ([AttRow], [Session], String?) -> Void) {
        self.onDone = onDone
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
        busy = false
    }

    // MARK: - Polling

    /// Waits for the router to reach the dashboard, then reads until the row set
    /// stops changing. The cards populate well after the document finishes
    /// loading, so a single read almost always comes back empty.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }

            var lastSignature = ""
            var stableReads = 0
            var sawDashboard = false

            for tick in 0..<180 {  // ~90s ceiling
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }

                let path = (((try? await self.eval(Scrapers.route)) ?? nil) as? String) ?? ""
                guard path.contains(Portal.dashboardMarker) else {
                    if tick == 40 && !sawDashboard {
                        self.status = "Still on the login page. Solve the captcha and wait for the dashboard."
                    }
                    continue
                }

                if !sawDashboard {
                    sawDashboard = true
                    self.status = "Dashboard reached. Reading your classes and attendance."
                }

                let (rows, sessions, cardFound) = await self.readOnce()
                if self.student == nil { self.student = await self.readStudent() }

                let signature = rows.map { "\($0.key):\($0.attended)/\($0.total)" }.joined(separator: ",")
                stableReads = (!rows.isEmpty && signature == lastSignature) ? stableReads + 1 : 0
                lastSignature = signature

                if !rows.isEmpty {
                    self.status = "Found \(rows.count) subjects, \(sessions.count) classes today."
                } else if cardFound {
                    self.status = "Found the attendance card, waiting for it to fill in."
                }

                // Two identical reads in a row means the cards have settled.
                if !rows.isEmpty && stableReads >= 2 {
                    self.finish(rows: rows, sessions: sessions)
                    return
                }
            }

            self.status = "Gave up waiting for the dashboard. Try again, and make sure it is fully loaded."
            self.busy = false
        }
    }

    private(set) var student: String?

    private struct NamePayload: Decodable {
        let ok: Bool
        let name: String?
    }

    private func readStudent() async -> String? {
        guard let raw = ((try? await eval(Scrapers.student)) ?? nil) as? String,
            let data = raw.data(using: .utf8),
            let p = try? JSONDecoder().decode(NamePayload.self, from: data),
            p.ok
        else { return nil }
        return p.name
    }

    private func finish(rows: [AttRow], sessions: [Session]) {
        pollTask?.cancel()
        pollTask = nil
        showingLogin = false
        busy = false
        status = nil
        onDone?(rows, sessions, student)
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
        var rows: [AttRow] = []
        var cardFound = false
        if let raw = ((try? await eval(Scrapers.attendance)) ?? nil) as? String,
            let data = raw.data(using: .utf8),
            let p = try? JSONDecoder().decode(AttPayload.self, from: data)
        {
            rows = p.rows
            cardFound = p.cardFound ?? false
        }

        var sessions: [Session] = []
        if let raw = ((try? await eval(Scrapers.sessions)) ?? nil) as? String,
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
