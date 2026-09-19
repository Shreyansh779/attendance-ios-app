import Combine
import Foundation
import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var portal = Portal()

    @State private var snapshot: Snapshot? = Store.load()
    @State private var route: Route = .today
    @State private var menuOpen = false
    @State private var tick = Date()
    @State private var picked: String?
    @State private var didAutoOpen = false

    /// Motion is gentler, never absent, when the system asks for less of it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Recomputed each minute so "12 min left" and the live class stay honest
    /// without the user reopening the app.
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

    var body: some View {
        ZStack(alignment: .leading) {
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

            VStack(alignment: .leading, spacing: 0) {
                header

                if let msg = portal.status ?? staleNote {
                    Text(msg)
                        .font(.r(14.5, .medium))
                        .foregroundStyle(Color.warnInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .slab(.warnBG, radius: 22, pad: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
                        .padding(.top, 14)
                }

                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            // The drawer is a modal task, so the page behind it goes back
            // rather than just being dimmed - depth says "this is still here,
            // underneath" in a way a flat scrim cannot.
            .scaleEffect(menuOpen && !reduceMotion ? 0.95 : 1)
            // No blanket bottom padding: it left a dead band under the
            // scrolling lists, which clipped the last card and looked like
            // empty space. Each screen pads its own scroll content instead.

            // Kept in the hierarchy so WebKit doesn't throttle it; see the
            // full-size copies at the bottom of the stack.
            if menuOpen {
                Color(0x090B0F).opacity(0.62)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(Motion.panel.reduced(reduceMotion)) { menuOpen = false } }
            }

            if menuOpen {
                Drawer(
                    route: $route,
                    day: day,
                    summary: summary,
                    snapshot: snapshot,
                    student: snapshot?.student,
                    photo: snapshot?.photo,
                    weekDays: snapshot?.week.count ?? 0,
                    busy: portal.busy,
                    onSelect: { r in
                        // Only a menu tap resets the pinned class. Doing this
                        // in onChange(of: route) also caught the timetable's
                        // own navigation and cleared the class just tapped.
                        if r == .today { picked = nil }
                        route = r
                    },
                    onRefresh: refresh,
                    close: { withAnimation(Motion.panel.reduced(reduceMotion)) { menuOpen = false } }
                )
                .frame(width: 306)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .leading))
            }
        }
        .animation(Motion.panel.reduced(reduceMotion), value: menuOpen)
        .preferredColorScheme(.dark)
        // Causality: the tap moved the drawer, so the tap is what you feel.
        .sensoryFeedback(.impact(weight: .light), trigger: menuOpen)
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
            if snapshot?.rows.isEmpty ?? true { refresh() }
            // A re-signed sideload is a reinstall, and a reinstall clears the
            // pending queue - so rebuild it every launch, not only on refresh.
            rescheduleReminders()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(Motion.panel.reduced(reduceMotion)) { menuOpen = true }
            } label: {
                VStack(spacing: 4) {
                    Capsule().fill(Color.ink2).frame(width: 15, height: 2)
                    Capsule().fill(Color.ink2).frame(width: 15, height: 2)
                }
                .frame(width: 40, height: 40)
                .background(Color.sur, in: Circle())
            }
            .buttonStyle(.pressable)

            Text(title)
                .font(.r(16, .semibold))
                .foregroundStyle(Color.ink3)

            Spacer(minLength: 0)

            Text(subtitle)
                .font(.r(14, .medium))
                .foregroundStyle(Color.ink4)
        }
    }

    @ViewBuilder private var content: some View {
        if snapshot == nil || (snapshot?.rows.isEmpty ?? true) {
            VStack {
                Spacer()
                Text("Nothing saved yet. Open the menu and tap refresh, then log in — today's classes and your attendance land here.")
                    .font(.r(16, .medium))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                Spacer()
            }
        } else {
            switch route {
            case .today:
                TodayView(
                    day: day,
                    nowMin: nowMin,
                    terms: terms,
                    picked: $picked,
                    marks: snapshot?.marks ?? [:],
                    today: Snapshot.isoDay.string(from: tick),
                    onMark: mark
                )
            case .timetable:
                TimetableView(
                    day: day,
                    nowMin: nowMin,
                    week: snapshot?.week ?? [:],
                    rows: rows,
                    today: Snapshot.isoDay.string(from: tick),
                    onOpenToday: { id in
                        picked = id
                        route = .today
                    }
                )
            case .attendance:
                AttendanceView(
                    summary: summary,
                    terms: terms,
                    // Tied to the same guard, so the header cannot announce a
                    // term end that the rows below have gone quiet about.
                    termEnd: terms.isEmpty ? nil : snapshot?.termEnd
                )
            }
        }
    }

    private var title: String {
        switch route {
        case .today: return snapshot?.student ?? "Today"
        case .timetable: return "Timetable"
        case .attendance: return "Attendance"
        }
    }

    private var subtitle: String {
        switch route {
        case .attendance:
            return summary.subjects.isEmpty ? "" : String(format: "%.1f%%", summary.overall.pct)
        case .timetable:
            return ""
        case .today:
            let left = day.filter { !$0.past }.count
            if day.isEmpty { return "" }
            return left > 0 ? "\(left) left" : "done"
        }
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
        withAnimation(Motion.panel.reduced(reduceMotion)) { menuOpen = false }
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
        VStack(spacing: 0) {
            HStack {
                Text("Portal login")
                    .font(.r(16, .semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("Done") { portal.cancel() }
                    .font(.r(16, .semibold))
                    .foregroundStyle(Color.mintHi)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.bg)

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
        .preferredColorScheme(.dark)
    }
}
