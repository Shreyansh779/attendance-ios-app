import Combine
import Foundation
import SwiftUI
import UIKit

/// The three screens, as a real tab bar.
///
/// This used to be a hamburger drawer, which is a Material Design pattern — no
/// Apple app on the phone has one. A tab bar is what iOS users already know,
/// and on iOS 26 the system gives it Liquid Glass for free.
enum Route: String, CaseIterable, Hashable {
    case today, timetable, attendance

    var title: String {
        switch self {
        case .today: return "Today"
        case .timetable: return "Timetable"
        case .attendance: return "Attendance"
        }
    }

    /// SF Symbols, rather than the hand-drawn circles and bars this app used to
    /// carry. They come weight-matched to the system font and adapt on their own.
    var symbol: String {
        switch self {
        case .today: return "location.fill"
        case .timetable: return "calendar"
        case .attendance: return "chart.bar.fill"
        }
    }
}

struct RootView: View {
    @StateObject private var portal = Portal()

    @State private var snapshot: Snapshot? = Store.load()
    @State private var route: Route = .today
    @State private var tick = Date()
    @State private var picked: String?
    @State private var didAutoOpen = false

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
            if portal.hostingHidden {
                PortalWebView(webView: portal.webView)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Color.bg.ignoresSafeArea()

            if hasData {
                tabs
            } else {
                emptyState
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: route)
        .onReceive(clock) { tick = $0 }
        .fullScreenCover(isPresented: $portal.showingLogin) {
            LoginSheet(portal: portal)
        }
        // Nothing stored means nothing to look at, so go straight to the portal
        // rather than showing an empty screen and an instruction.
        .onAppear {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            if !hasData { refresh() }
            // A re-signed sideload is a reinstall, and a reinstall clears the
            // pending queue - so rebuild it every launch, not only on refresh.
            rescheduleReminders()
        }
    }

    // MARK: - Tabs

    private var tabs: some View {
        TabView(selection: $route) {
            Tab(Route.today.title, systemImage: Route.today.symbol, value: Route.today) {
                screen(title: snapshot?.student ?? "Today", leadingAvatar: true) {
                    TodayView(
                        day: day,
                        nowMin: nowMin,
                        terms: terms,
                        picked: $picked,
                        marks: snapshot?.marks ?? [:],
                        today: today,
                        onMark: mark
                    )
                }
            }

            Tab(Route.timetable.title, systemImage: Route.timetable.symbol, value: Route.timetable) {
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
                        }
                    )
                }
            }

            Tab(Route.attendance.title, systemImage: Route.attendance.symbol, value: Route.attendance) {
                screen(title: Route.attendance.title) {
                    AttendanceView(
                        summary: summary,
                        terms: terms,
                        // Tied to the same guard, so the header cannot announce
                        // a term end the rows below have gone quiet about.
                        termEnd: terms.isEmpty ? nil : snapshot?.termEnd,
                        weekDays: snapshot?.week.count ?? 0,
                        weekDiag: snapshot?.weekDiag,
                        age: snapshot?.ageText
                    )
                }
            }
        }
        .tint(Color.mintHi)
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
                .background(Color.bg)
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
                }
                .safeAreaInset(edge: .top) {
                    if let msg = portal.status ?? staleNote {
                        Text(msg)
                            .font(.r(14.5, .medium))
                            .foregroundStyle(Color.warnInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .slab(
                                .warnBG, radius: 22,
                                pad: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)
                            )
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.ink3)
            Text("Nothing saved yet")
                .font(.r(22, .semibold))
                .foregroundStyle(Color.ink)
            Text("Sign in to the portal and your classes and attendance land here.")
                .font(.r(16, .medium))
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the portal") { refresh() }
                .font(.r(16, .semibold))
                .buttonStyle(.borderedProminent)
                .tint(Color.mintHi)
                .foregroundStyle(Color(0x1B2C24))
                .disabled(portal.busy)
                .padding(.top, 4)
            if let msg = portal.status {
                Text(msg)
                    .font(.r(13.5, .medium))
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
            snap.marks[key] = Mark(subject: subject, attended: a)
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
        portal.begin(knownStudent: snapshot?.student) { r in
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
                // A fresh read from the portal is authoritative, so hand marks
                // are spent.
                marks: [:],
                weekDiag: r.weekDiag,
                // A read that only managed the agenda keeps whatever term end
                // an earlier whole-term read established.
                termEnd: r.termEnd ?? snapshot?.termEnd,
                photo: r.photo ?? snapshot?.photo
            )
            Store.save(snap)
            snapshot = snap
            picked = nil
            tick = Date()
            rescheduleReminders()
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
                        .font(.r(13.5, .medium))
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
        .preferredColorScheme(.dark)
    }
}
