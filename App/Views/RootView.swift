import Combine
import Foundation
import SwiftUI
import UIKit

/// The four screens, as a real tab bar.
///
/// This used to be a hamburger drawer, which is a Material Design pattern — no
/// Apple app on the phone has one. A tab bar is what iOS users already know,
/// and on iOS 26 the system gives it Liquid Glass for free.
enum Route: String, CaseIterable, Hashable {
    case today, timetable, attendance, lms

    var title: String {
        switch self {
        case .today: return "Today"
        case .timetable: return "Timetable"
        case .attendance: return "Attendance"
        case .lms: return "LMS"
        }
    }

    /// SF Symbols, rather than the hand-drawn circles and bars this app used to
    /// carry. They come weight-matched to the system font and adapt on their own.
    var symbol: String {
        switch self {
        case .today: return "location.fill"
        case .timetable: return "calendar"
        case .attendance: return "chart.bar.fill"
        case .lms: return "books.vertical.fill"
        }
    }
}

struct RootView: View {
    /// New York on the navigation bar, and a material behind it.
    ///
    /// SwiftUI has no modifier for the large-title font, so this is the one
    /// place UIKit still has to be asked. Transparent would let content slide
    /// under bare text; the default background is the system's own glass,
    /// which is exactly what the rest of the app is made of.
    init() {
        let bar = UINavigationBarAppearance()
        bar.configureWithDefaultBackground()
        bar.largeTitleTextAttributes = [
            .font: Display.uiFont(33, .bold), .kern: -0.5,
        ]
        bar.titleTextAttributes = [.font: Display.uiFont(17, .semibold)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }

    @StateObject private var portal = Portal()
    @StateObject private var direct = PortalDirect()

    @State private var snapshot: Snapshot? = Store.load()
    @State private var route: Route = RootView.firstRoute
    @State private var tick = Date()
    @State private var picked: String?
    @State private var didAutoOpen = false
    @State private var showingSettings = RootView.opensSettings
    @State private var showingProfile = false

    /// Where a screenshot run wants to land. Release builds always start on
    /// Today, because `Demo` does not exist in them.
    private static var firstRoute: Route {
        #if DEBUG
            if Demo.isOn {
                if Demo.tab == "subject" { return .attendance }
                if let r = Route(rawValue: Demo.tab) { return r }
            }
        #endif
        return .today
    }

    private static var opensSettings: Bool {
        #if DEBUG
            return Demo.isOn && Demo.showsSettings
        #endif
        #if !DEBUG
            return false
        #endif
    }

    /// A screenshot of the subject screen needs the subject screen on top, and
    /// nothing else in the app can put it there without a tap.
    private static var showsSubject: Bool {
        #if DEBUG
            return Demo.isOn && Demo.tab == "subject"
        #endif
        #if !DEBUG
            return false
        #endif
    }

    /// Motion is gentler, never absent, when the system asks for less of it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Recomputed each half-minute so "12 min left" and the live class stay
    /// honest without the user reopening the app.
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var nowMin: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: tick)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Marks are folded in before anything is displayed, so a hand-ticked class
    /// moves every number in the app at once.
    private var rows: [AttRow] {
        guard let s = snapshot else { return [] }
        return applyMarks(s.rows, s.marks)
    }

    private var day: [Klass] {
        guard let s = snapshot else { return [] }
        return shapeDay(sessions: s.sessions(for: tick), rows: rows, nowMin: nowMin)
    }

    /// Shaped with a clock of -1, so nothing in it reads as past or live.
    private var tomorrow: [Klass] {
        guard let s = snapshot,
            let next = Calendar.current.date(byAdding: .day, value: 1, to: tick)
        else { return [] }
        return shapeDay(sessions: s.sessions(for: next), rows: rows, nowMin: -1)
    }

    private var summary: Summary { Summary(rows) }

    /// Only computed when the whole term is known and has not already run out;
    /// on a few days of agenda the honest answer is to say nothing.
    private var terms: [String: Term] {
        guard let s = snapshot, let end = s.termEnd,
            end >= Snapshot.isoDay.string(from: tick)
        else { return [:] }
        return termMap(rows: rows, upcoming: s.upcoming(from: tick))
    }

    private var hasData: Bool { !(snapshot?.rows.isEmpty ?? true) }

    /// Either data source can be the one doing the work right now.
    private var busy: Bool { portal.busy || direct.busy }
    private var status: String? { direct.status ?? portal.status }

    private var today: String { Snapshot.isoDay.string(from: tick) }

    var body: some View {
        ZStack {
            // The live webview, full size, underneath an opaque background.
            //
            // It used to be pinned to 1x1pt while reading in the background,
            // which is what actually broke the weekly timetable: WKWebView
            // lays the page out at the view's own size, the portal's Kendo
            // scheduler measures its container before rendering rows, and at
            // a 1x1 viewport it renders none - so the scrape always came back
            // with an empty table no matter how long it waited. Full size and
            // covered keeps WebKit's timers unthrottled (the view is still in
            // the window) while the page lays out as if it were on screen.
            if portal.hostingHidden, !portal.showingLogin, !portal.showingVisit {
                PortalWebView(webView: portal.webView)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Backdrop()

            if hasData {
                tabs
                PillBar(route: $route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if busy {
                loadingState
            } else {
                emptyState
            }
        }
        .animation(Motion.ui.reduced(reduceMotion), value: hasData)
        .animation(Motion.ui.reduced(reduceMotion), value: busy)
        // Text scales with the reader's setting, but only so far: past
        // accessibility1 a 92pt room number stops being a layout and starts
        // being a single digit. The hero keeps minimumScaleFactor as well.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sensoryFeedback(.selection, trigger: route)
        .onReceive(clock) { tick = $0 }
        .fullScreenCover(isPresented: $direct.showingLogin) {
            DirectLoginSheet(direct: direct)
        }
        .fullScreenCover(isPresented: $portal.showingLogin) {
            LoginSheet(portal: portal)
        }
        .fullScreenCover(isPresented: $portal.showingVisit) {
            VisitSheet(portal: portal)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                weekDays: snapshot?.week.count ?? 0,
                weekDiag: snapshot?.weekDiag,
                registerRows: snapshot?.daywise.count ?? 0,
                attDiag: snapshot?.attDiag,
                dueCount: snapshot?.deadlines.count ?? 0,
                courseCount: snapshot?.courses.count ?? 0,
                lmsDiag: snapshot?.lmsDiag,
                hasPhoto: snapshot?.photo != nil,
                photoDiag: snapshot?.photoDiag,
                directError: direct.lastError,
                age: snapshot?.ageText,
                onSettingsChanged: rescheduleReminders,
                onClearCache: {
                    Store.clear()
                    snapshot = nil
                    picked = nil
                    rescheduleReminders()
                },
                onForceWebView: { refreshViaWebView() }
            )
        }
        .sheet(isPresented: $showingProfile) {
            ProfileSheet(profile: snapshot?.profile, photo: photoImage)
        }
        // A fresh install used to throw the portal's login page up the instant
        // it opened, before the app had shown itself at all. Opening an app
        // and being handed somebody else's website is a jarring first second;
        // the empty state says what is missing and offers the same button.
        .onAppear {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            #if DEBUG
                // The authorisation prompt is a system alert over whatever the
                // screenshot was meant to be of.
                if Demo.isOn { return }
            #endif
            // A re-signed sideload is a reinstall, and a reinstall clears the
            // pending queue - so rebuild it every launch, not only on refresh.
            rescheduleReminders()
        }
    }

    // MARK: - Tabs

    private var tabs: some View {
        ZStack {
            pane(.today) {
                screen(title: snapshot?.student ?? "Today", leadingAvatar: true) {
                    TodayView(
                        day: day,
                        nowMin: nowMin,
                        terms: terms,
                        blocker: summary.blocker,
                        tomorrow: tomorrow,
                        picked: $picked,
                        marks: snapshot?.marks ?? [:],
                        today: today,
                        due: snapshot?.deadlines ?? [],
                        onMark: mark
                    )
                }
            }

            pane(.timetable) {
                screen(title: Route.timetable.title) {
                    TimetableView(
                        day: day,
                        nowMin: nowMin,
                        week: snapshot?.week ?? [:],
                        rows: rows,
                        today: today,
                        onOpenToday: { id in
                            picked = id
                            route = .today
                        },
                        marks: snapshot?.marks ?? [:],
                        onMark: mark,
                        holidays: snapshot?.holidays ?? []
                    )
                }
            }

            pane(.attendance) {
                screen(title: RootView.showsSubject ? "Subject" : Route.attendance.title) {
                    subjectOrList
                }
            }

            pane(.lms) {
                screen(title: Route.lms.title) {
                    LmsView(courses: snapshot?.courses ?? []) { link in
                        if let u = URL(string: link) { portal.visit(u) }
                    }
                }
            }
        }
        .tint(Color.ink)
        // An LMS link only works inside the portal's webview - Safari has no
        // Moodle session - so every one, wherever it is tapped, goes there.
        .environment(\.openURL, OpenURLAction { url in
            guard url.host == Portal.lmsHost else { return .systemAction }
            openLMS(url)
            return .handled
        })
        .animation(Motion.ui.reduced(reduceMotion), value: route)
    }

    @ViewBuilder
    private var subjectOrList: some View {
        if RootView.showsSubject, let row = summary.subjects.first {
            SubjectView(
                row: row,
                term: terms[row.key],
                blocker: summary.blocker,
                daywise: (snapshot?.daywise ?? []).filter { $0.subject == row.key }
            )
        } else {
            AttendanceView(
                summary: summary,
                terms: terms,
                daywise: snapshot?.daywise ?? [],
                now: tick
            )
        }
    }

    /// One screen of the three, cross-fading rather than cutting.
    ///
    /// This was a TabView. Once the tab bar became a custom one the only thing
    /// TabView still contributed was an instant, animation-free swap - which
    /// reads as a dropped frame rather than as a change of screen. Keeping all
    /// three mounted also means paging the timetable survives a trip to
    /// Attendance and back.
    @ViewBuilder
    private func pane<Content: View>(_ r: Route, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(route == r ? 1 : 0)
            .allowsHitTesting(route == r)
            .accessibilityHidden(route != r)
    }

    /// One screen's chrome: a real navigation bar, the refresh control, and the
    /// status line — so every tab answers "where am I / what can I do here" the
    /// same way.
    @ViewBuilder
    private func screen<Content: View>(
        title: String,
        leadingAvatar: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Clear, not bg: the backdrop is one layer down and every card
                // on this screen is blurring it. An opaque screen background
                // would give them nothing to see.
                .background(Color.clear)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if leadingAvatar, let img = photoImage {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showingProfile = true } label: {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 30, height: 30)
                                    .clipShape(Circle())
                            }
                            .accessibilityLabel("Your profile")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.rotate, isActive: busy && !reduceMotion)
                        }
                        .disabled(busy)
                        .accessibilityLabel("Refresh from portal")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                // The pill bar floats over the content, so the content has
                // to be told to end above it.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 66)
                }
                // At the bottom, over the content, rather than pinned under
                // the navigation bar. As a top inset it sat between the large
                // title and the screen and did not move when either did -
                // the same complaint the timetable's date stepper drew. Down
                // here it is a passing notice about a background job, which is
                // what it is, and it collides with nothing.
                .overlay(alignment: .bottom) {
                    if let msg = status ?? staleNote {
                        Text(msg)
                            .p(14)
                            .foregroundStyle(Color.warnInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 22))
                            .padding(.horizontal, 20)
                            // Clear of the tab bar, which floats over the same
                            // corner of the screen.
                            .padding(.bottom, 70)
                            .transition(.soft)
                    }
                }
                .animation(Motion.ui.reduced(reduceMotion), value: status)
        }
    }

    /// The shape of the screen that is coming, while it is being read.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Skeleton(height: 40, radius: 20).frame(width: 190)
            Skeleton(height: 150, radius: 28)
            Skeleton(height: 104, radius: 28)
            Skeleton(height: 76, radius: 28)
            if let msg = status {
                Text(msg)
                    .p(13.5)
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 70)
        .transition(.soft)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.ink3)
            Text("Nothing saved yet")
                .d(24, .bold)
                .foregroundStyle(Color.ink)
            Text("Sign in to the portal and your classes and attendance land here.")
                .r(16, .medium)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the portal") { refresh() }
                .r(16, .semibold)
                .buttonStyle(.borderedProminent)
                .tint(Color.ink)
                .foregroundStyle(Color.onInk)
                .disabled(busy)
                .padding(.top, 4)
            if let msg = status {
                Text(msg)
                    .r(13.5, .medium)
                    .foregroundStyle(Color.warnInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The empty state has no navigation bar, so no way to reach
            // Settings' diagnostics - this is the only place a fallback's
            // real cause is visible before there's any data to put a
            // Settings gear next to.
            if let err = direct.lastError {
                Text("Direct connection failed: \(err)")
                    .r(12, .medium)
                    .foregroundStyle(Color.ink3)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .transition(.soft)
    }

    // MARK: - Pieces

    /// Decoded from the `data:` URI the dashboard header carries.
    private var photoImage: UIImage? {
        guard let p = snapshot?.photo,
            let comma = p.firstIndex(of: ","),
            let data = Data(base64Encoded: String(p[p.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }

    private var staleNote: String? {
        guard let s = snapshot, !s.rows.isEmpty, s.ageHours > 12 else { return nil }
        return "This is saved from earlier. Refresh to bring it up to date."
    }

    /// Ticking a class off locally. Tapping the same answer again clears it.
    private func mark(_ key: String, _ subject: String, _ attended: Bool?) {
        guard var snap = snapshot else { return }
        if let a = attended {
            // The portal's own total, not the marked one, or the baseline
            // would drift every time you ticked something.
            let seen = matchSubject(subject, in: snap.rows)?.total ?? 0
            snap.marks[key] = Mark(subject: subject, attended: a, total: seen)
        } else {
            snap.marks.removeValue(forKey: key)
        }
        // Fired here rather than with .sensoryFeedback(trigger:) on the
        // control, because that form also fires when you merely pin a
        // different class that already carries a mark. Feedback has to follow
        // the cause, or it trains you to ignore it.
        UIImpactFeedbackGenerator(style: attended == nil ? .light : .medium)
            .impactOccurred()
        Store.save(snap)
        withAnimation(Motion.ui.reduced(reduceMotion)) { snapshot = snap }
    }

    /// Fire-and-forget: reminders are a convenience, and nothing in the UI
    /// should wait on the notification centre.
    private func rescheduleReminders() {
        guard let snap = snapshot, !snap.rows.isEmpty else { return }
        let terms = self.terms
        let rows = self.rows
        Task { await Notify.reschedule(from: snap, terms: terms, rows: rows) }
    }

    /// Tried first, every refresh: plain HTTP, no captcha, no WebView. Falls
    /// back to `portal`'s WKWebView flow on anything but a missing session -
    /// a missing session shows `direct`'s own login form instead, since that
    /// is the normal, better path, not a broken one.
    private func refresh() {
        direct.onSignedIn = { [self] in refresh() }
        direct.moodleCookies = { [portal] in await portal.allCookies() }
        Task {
            do {
                let r = try await direct.begin(
                    knownStudent: snapshot?.student,
                    knownHolidays: snapshot?.holidays ?? [],
                    knownCourses: snapshot?.courses ?? []
                )
                direct.lastError = nil
                apply(r)
                if r.deadlines == nil {
                    // Rather than keep chasing the LMS handoff from the
                    // direct side, this quietly runs the already-reliable
                    // WebView flow in the background for just this gap. It
                    // won't show a captcha login unless the stored session
                    // has actually expired.
                    //
                    // The WebView's own lmsDiag overwrites r.lmsDiag the
                    // moment that fallback's `apply` runs below, so the
                    // direct attempt's actual reason has to be captured here
                    // first or it's gone - without this, "why did it fall
                    // back to the WebView for LMS" was undiagnosable the
                    // moment the WebView fallback itself succeeded or failed
                    // with its own, unrelated message.
                    direct.lastError = "LMS direct attempt: \(r.lmsDiag ?? "unknown")"
                    refreshViaWebView()
                }
            } catch is PortalDirect.DirectError {
                // direct.showingLogin is already up; nothing else to do here.
            } catch {
                // What actually broke, kept for Settings - without this, a
                // fallback is silent and there is no way to tell from the
                // device why the direct path gave up.
                direct.lastError = "\(error)"
                refreshViaWebView()
            }
        }
    }

    private func refreshViaWebView() {
        portal.begin(
            knownStudent: snapshot?.student,
            knownHolidays: snapshot?.holidays ?? []
        ) { r in apply(r) }
    }

    /// Open an LMS link in the webview cover. When the deadlines came over REST
    /// the webview was never signed into Moodle, so the raw link lands on the
    /// login - so first mint an autologin URL from the stored token (the way the
    /// real app opens its links) and let the webview sign itself in on the way.
    /// Falls back to the plain link, which `portal.visit` still signs into by
    /// hand, whenever there is no token or the key throttle/refusal returns nil.
    private func openLMS(_ url: URL) {
        Task {
            guard let saved = MoodleTokenStore.load() else {
                direct.lastError = "autologin: no stored token"
                portal.visit(url)
                return
            }
            // Moodle locks key generation to one request every few minutes. After
            // a successful autologin the webview session carries the next taps, so
            // inside that window open the link plainly rather than re-minting into
            // the lockout.
            if let last = portal.lastMoodleAutoLogin, Date().timeIntervalSince(last) < 360 {
                direct.lastError = "autologin: within lockout window, using live session"
                portal.visit(url)
                return
            }
            let (auto, why) = await PortalMoodle.autoLoginURL(
                wstoken: saved.token, privateToken: saved.privateToken, target: url
            )
            // Kept in the Settings "Direct connection" card so a tap that still
            // lands on the login can say why the token sign-in did not take.
            direct.lastError = "autologin(\(url.lastPathComponent)): \(why)"
            if let auto {
                portal.lastMoodleAutoLogin = Date()
                portal.visit(auto, appUA: true)
            } else {
                portal.visit(url)
            }
        }
    }

    private func apply(_ r: Portal.Reading) {
        // Merge rather than replace: the agenda only shows six days, so old
        // days stay cached until they are superseded.
        var merged = snapshot?.week ?? [:]
        // A whole-term read lists every day that has classes, so a cached
        // day it no longer lists has lost them (cancelled, or moved) and
        // must go - otherwise the old classes, reminders included, outlive
        // the portal's. A partial read says nothing about absent days.
        // Days older than the payload reaches stay: nothing re-reads them.
        if r.termEnd != nil, let first = r.week.keys.min() {
            merged = merged.filter { $0.key < first }
        }
        for (day, list) in r.week { merged[day] = list }

        let snap = Snapshot(
            savedAt: Date(),
            rows: r.rows,
            sessions: r.sessions,
            student: r.student ?? snapshot?.student,
            week: merged,
            // Only the marks the portal has actually absorbed are spent;
            // the rest survive a refresh that beat the portal to it.
            marks: survivingMarks(snapshot?.marks ?? [:], after: r.rows),
            weekDiag: r.weekDiag,
            // A read that only managed the agenda keeps whatever term end
            // an earlier whole-term read established.
            termEnd: r.termEnd ?? snapshot?.termEnd,
            history: Snapshot.extend(snapshot?.history ?? [], with: r.rows, on: Date()),
            holidays: r.holidays.isEmpty ? (snapshot?.holidays ?? []) : r.holidays,
            daywise: r.daywise.isEmpty ? (snapshot?.daywise ?? []) : r.daywise,
            attDiag: r.attDiag ?? snapshot?.attDiag,
            photo: r.photo ?? snapshot?.photo,
            photoDiag: r.photoDiag ?? snapshot?.photoDiag,
            // ?? rather than isEmpty: a read that legitimately found
            // nothing has to be able to clear what the last one left, and
            // an empty list said both that and "this did not run".
            deadlines: r.deadlines ?? snapshot?.deadlines ?? [],
            lmsDiag: r.lmsDiag ?? snapshot?.lmsDiag,
            courses: r.courses ?? snapshot?.courses ?? [],
            faculty: r.faculty.isEmpty ? (snapshot?.faculty ?? [:]) : r.faculty,
            profile: r.profile ?? snapshot?.profile
        )
        Store.save(snap)
        withAnimation(Motion.ui.reduced(reduceMotion)) { snapshot = snap }
        picked = nil
        tick = Date()
        rescheduleReminders()
    }
}

/// A floating capsule of glass, clear of every edge.
///
/// The selected tab is the only filled thing on the screen - ink on glass,
/// carrying its label; the others are icons alone. The fill slides between
/// them rather than cutting, which is the whole of the animation.
private struct PillBar: View {
    @Binding var route: Route

    var body: some View {
        SlideBar(items: Route.allCases, selection: $route) { r, on in
            HStack(spacing: 5) {
                Image(systemName: r.symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                if on {
                    Text(r.title)
                        .r(13, .semibold)
                        .lineLimit(1)
                        // "Attendance" is wider than a third of the bar at any
                        // sensible size, so it is allowed to shrink rather than
                        // to spill over the edge of its own thumb.
                        .minimumScaleFactor(0.65)
                }
            }
            .foregroundStyle(on ? Color.onInk : Color.ink3)
            .padding(.horizontal, 8)
            .padding(.vertical, 11)
            .accessibilityLabel(r.title)
            .accessibilityAddTraits(on ? [.isSelected] : [])
        }
        .padding(5)
        .glassy(Capsule(), tint: .well, material: .ultraThinMaterial)
        .padding(.horizontal, 26)
        .padding(.bottom, 6)
    }
}

/// One LMS link, in the app's own webview.
///
/// Not Safari: the Moodle session lives in this webview and nowhere else, so
/// a link handed to the system browser lands on a login form that nothing can
/// get past. If the session has lapsed, `Portal.visit` rebuilds it underneath
/// — which may mean the portal's own login page appearing here first, and the
/// link opening by itself once it is done.
private struct VisitSheet: View {
    @ObservedObject var portal: Portal

    /// The file to hand the share sheet, once it has been fetched. Nil while
    /// there is nothing to share, which is also what dismissing it restores.
    @State private var sharing: Shared?
    @State private var fetching = false

    /// A downloaded file, wrapped only because `.sheet(item:)` needs identity.
    private struct Shared: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let s = portal.status {
                    Text(s)
                        .r(13.5, .medium)
                        .foregroundStyle(Color.warnInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .background(Color.bg)
                }
                PortalWebView(webView: portal.webView)
                    .overlay {
                        ZStack {
                            if portal.visitHidden {
                                ZStack {
                                    Color.bg
                                    ProgressView()
                                }
                                .transition(.opacity)
                            }
                        }
                        .animation(Motion.gentle, value: portal.visitHidden)
                    }
            }
            .background(Color.bg)
            .navigationTitle(portal.visitTitle ?? "LMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        fetching = true
                        Task {
                            if let u = await portal.downloadVisible() { sharing = Shared(url: u) }
                            fetching = false
                        }
                    } label: {
                        if fetching {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(fetching)
                    .accessibilityLabel("Share this document")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { portal.endVisit() }
                }
            }
            .sheet(item: $sharing) { ShareSheet(url: $0.url) }
        }
    }
}

/// The system share sheet. SwiftUI's `ShareLink` needs its file up front, and
/// this one does not exist until it has been fetched.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What the direct API path learned about the student beyond name and photo.
/// Empty whenever only the WebView path has ever run - it never reads any of
/// this.
private struct ProfileSheet: View {
    let profile: StudentProfile?
    let photo: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let img = photo {
                    HStack {
                        Spacer()
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                if let p = profile {
                    Section {
                        row("Name", p.name)
                        row("Email", p.email)
                        row("Phone", p.phone)
                        row("Campus", p.campus)
                        row("Programme", p.program)
                        row("Student ID", p.studentId)
                        row("Global ID", p.globalId)
                    }
                } else {
                    Text("Only available after a refresh over the direct connection, not the portal login.")
                        .foregroundStyle(Color.ink2)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label).foregroundStyle(Color.ink2)
                Spacer()
                Text(value)
            }
        }
    }
}

/// Email + password, for the direct API path.
///
/// No captcha here - the mobile endpoint takes a literal `"-"` for it, which
/// is the whole reason this doesn't need to be a WebView.
private struct DirectLoginSheet: View {
    @ObservedObject var direct: PortalDirect
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                if let error = direct.loginError {
                    Text(error).foregroundStyle(Color.warnInk)
                }
            }
            .navigationTitle("Portal login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { direct.cancelLogin() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        signingIn = true
                        Task {
                            await direct.login(email: email, password: password)
                            signingIn = false
                        }
                    } label: {
                        if signingIn { ProgressView() } else { Text("Sign in") }
                    }
                    .disabled(signingIn || email.isEmpty || password.isEmpty)
                }
            }
        }
    }
}

/// The portal, on screen, with the live webview so cookies survive.
private struct LoginSheet: View {
    @ObservedObject var portal: Portal

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let s = portal.status {
                    Text(s)
                        .r(13.5, .medium)
                        .foregroundStyle(Color.warnInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .background(Color.bg)
                }
                PortalWebView(webView: portal.webView)
            }
            .background(Color.bg)
            .navigationTitle("Portal login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { portal.cancel() }
                }
            }
        }
    }
}
