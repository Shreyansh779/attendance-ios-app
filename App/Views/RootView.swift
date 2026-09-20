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

    @State private var snapshot: Snapshot? = Store.load()
    @State private var route: Route = RootView.firstRoute
    @State private var tick = Date()
    @State private var picked: String?
    @State private var didAutoOpen = false
    @State private var showingSettings = RootView.opensSettings

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
            } else if portal.busy {
                loadingState
            } else {
                emptyState
            }
        }
        .animation(Motion.ui.reduced(reduceMotion), value: hasData)
        // Text scales with the reader's setting, but only so far: past
        // accessibility1 a 92pt room number stops being a layout and starts
        // being a single digit. The hero keeps minimumScaleFactor as well.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // No forced scheme. Every colour is a solved light/dark pair now, so
        // the app follows the phone instead of insisting.
        .sensoryFeedback(.selection, trigger: route)
        .onReceive(clock) { tick = $0 }
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
                age: snapshot?.ageText,
                onSettingsChanged: rescheduleReminders,
                onClearCache: {
                    Store.clear()
                    snapshot = nil
                    picked = nil
                    rescheduleReminders()
                }
            )
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
        .animation(Motion.ui.reduced(reduceMotion), value: route)
    }

    @ViewBuilder
    private var subjectOrList: some View {
        if RootView.showsSubject, let row = summary.subjects.first {
            SubjectView(
                row: row,
                term: terms[row.key],
                blocker: summary.blocker,
                history: snapshot?.history ?? [],
                daywise: (snapshot?.daywise ?? []).filter { $0.subject == row.key }
            )
        } else {
            AttendanceView(
                summary: summary,
                terms: terms,
                history: snapshot?.history ?? [],
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
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(portal.busy)
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
                    if let msg = portal.status ?? staleNote {
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
                .animation(Motion.ui.reduced(reduceMotion), value: portal.status)
        }
    }

    /// The shape of the screen that is coming, while it is being read.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Skeleton(height: 40, radius: 20).frame(width: 190)
            Skeleton(height: 150, radius: 28)
            Skeleton(height: 104, radius: 28)
            Skeleton(height: 76, radius: 28)
            if let msg = portal.status {
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
                .disabled(portal.busy)
                .padding(.top, 4)
            if let msg = portal.status {
                Text(msg)
                    .r(13.5, .medium)
                    .foregroundStyle(Color.warnInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
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

    private func refresh() {
        portal.begin(
            knownStudent: snapshot?.student,
            knownHolidays: snapshot?.holidays ?? []
        ) { r in
            // Merge rather than replace: the agenda only shows six days, so old
            // days stay cached until they are superseded.
            var merged = snapshot?.week ?? [:]
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
                deadlines: r.deadlines.isEmpty ? (snapshot?.deadlines ?? []) : r.deadlines,
                lmsDiag: r.lmsDiag ?? snapshot?.lmsDiag,
                courses: r.courses.isEmpty ? (snapshot?.courses ?? []) : r.courses,
                faculty: r.faculty.isEmpty ? (snapshot?.faculty ?? [:]) : r.faculty
            )
            Store.save(snap)
            snapshot = snap
            picked = nil
            tick = Date()
            rescheduleReminders()
        }
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
            .navigationTitle("LMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { portal.endVisit() }
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
