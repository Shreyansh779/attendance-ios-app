import Combine
import Foundation
import SwiftUI

struct RootView: View {
    @StateObject private var portal = Portal()

    @State private var snapshot: Snapshot? = Store.load()
    @State private var route: Route = .today
    @State private var menuOpen = false
    @State private var tick = Date()
    @State private var picked: String?
    @State private var didAutoOpen = false

    /// Recomputed each minute so "12 min left" and the live class stay honest
    /// without the user reopening the app.
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var nowMin: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: tick)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var day: [Klass] {
        guard let s = snapshot else { return [] }
        return shapeDay(sessions: s.sessions, rows: s.rows, nowMin: nowMin)
    }

    private var summary: Summary { Summary(snapshot?.rows ?? []) }

    var body: some View {
        ZStack(alignment: .leading) {
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
            .padding(.bottom, 20)

            if menuOpen {
                Color(0x090B0F).opacity(0.62)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.24)) { menuOpen = false } }
            }

            if menuOpen {
                Drawer(
                    route: $route,
                    day: day,
                    summary: summary,
                    snapshot: snapshot,
                    student: snapshot?.student,
                    onRefresh: refresh,
                    close: { withAnimation(.easeOut(duration: 0.24)) { menuOpen = false } }
                )
                .frame(width: 306)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .leading))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: menuOpen)
        .preferredColorScheme(.dark)
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
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.easeOut(duration: 0.26)) { menuOpen = true }
            } label: {
                VStack(spacing: 4) {
                    Capsule().fill(Color.ink2).frame(width: 15, height: 2)
                    Capsule().fill(Color.ink2).frame(width: 15, height: 2)
                }
                .frame(width: 40, height: 40)
                .background(Color.sur, in: Circle())
            }
            .buttonStyle(.plain)

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
            case .today: TodayView(day: day, nowMin: nowMin, picked: $picked)
            case .timetable: TimetableView(day: day, nowMin: nowMin)
            case .attendance: AttendanceView(summary: summary)
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
            return "Today"
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

    private func refresh() {
        withAnimation(.easeOut(duration: 0.2)) { menuOpen = false }
        portal.begin { rows, sessions, student in
            let snap = Snapshot(
                savedAt: Date(),
                rows: rows,
                sessions: sessions,
                student: student ?? snapshot?.student
            )
            Store.save(snap)
            snapshot = snap
            picked = nil
            tick = Date()
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
