import SwiftUI

struct TimetableView: View {
    /// Today, already shaped from the dashboard card. Used as a fallback for
    /// the today page when the weekly scrape has nothing for today, so this
    /// screen is never emptier than the dashboard.
    let day: [Klass]
    let nowMin: Int
    let week: [String: [Session]]
    let rows: [AttRow]
    let today: String
    /// Called with a Klass.id when a *today* row is tapped. RootView wires
    /// this to `picked = id; route = .today` — same as tapping the class on
    /// the dashboard itself.
    let onOpenToday: (String) -> Void

    @State private var idx = 0

    /// Continuous day-by-day range, today through the furthest date the
    /// portal has actually handed us — not just the days that happen to have
    /// a class, so a free day still gets a page instead of vanishing and
    /// throwing off the arrow count.
    private var dates: [String] {
        // The cache holds the whole term now, for the attendance maths. Paging
        // through three months one arrow at a time is not a timetable, so the
        // screen still stops at a fortnight - which is all the portal's own
        // agenda ever showed.
        let horizon = Snapshot.isoDay.string(
            from: Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
        )
        guard let maxKey = week.keys.filter({ $0 >= today && $0 <= horizon }).max(),
            let start = Snapshot.isoDay.date(from: today),
            let end = Snapshot.isoDay.date(from: maxKey),
            start <= end
        else { return [today] }

        var out: [String] = []
        var d = start
        let cal = Calendar.current
        while d <= end {
            out.append(Snapshot.isoDay.string(from: d))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    private var selectedKey: String {
        dates.indices.contains(idx) ? dates[idx] : today
    }

    private var list: [Klass] {
        let sessions = week[selectedKey] ?? []
        if sessions.isEmpty && selectedKey == today { return day }
        return shapeDay(
            sessions: sessions,
            rows: rows,
            nowMin: selectedKey == today ? nowMin : -1
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nav

            if list.isEmpty {
                Text("No classes this day.")
                    .font(.r(16, .medium))
                    .foregroundStyle(Color.ink2)
                    .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                    .padding(.top, 18)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(list) { k in
                            Row(
                                k: k, nowMin: nowMin,
                                tappable: selectedKey == today,
                                onTap: { onOpenToday(k.id) }
                            )
                        }
                    }
                    .padding(.bottom, 20)
                    .padding(.top, 18)
                }
            }
        }
        // Clamp if `week` shrinks (e.g. a fresh refresh with a shorter range)
        // and the current page no longer exists.
        .onChange(of: dates.count) { _, count in
            if idx >= count { idx = max(0, count - 1) }
        }
    }

    private var nav: some View {
        HStack(spacing: 12) {
            arrow("chevron.left", enabled: idx > 0) { idx -= 1 }

            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.r(21, .bold))
                    .kerning(-0.5)
                Text(dateLabel)
                    .font(.r(13.5, .medium))
                    .foregroundStyle(Color.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            arrow("chevron.right", enabled: idx < dates.count - 1) { idx += 1 }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func arrow(_ system: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.ink : Color.ink4)
                .frame(width: 36, height: 36)
                .background(Color.sur, in: Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
    }

    private var heading: String {
        selectedKey == today ? "Today" : weekday(selectedKey)
    }

    private var dateLabel: String {
        guard let d = Snapshot.isoDay.date(from: selectedKey) else { return selectedKey }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func weekday(_ key: String) -> String {
        guard let d = Snapshot.isoDay.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.wide))
    }

    private struct Row: View {
        @Environment(\.openURL) private var openURL

        let k: Klass
        let nowMin: Int
        let tappable: Bool
        let onTap: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(hhmm(k.s0)).font(.r(16, .bold)).kerning(-0.3)
                        Text(ampm(k.s0)).font(.r(11.5, .semibold)).foregroundStyle(Color.ink3)
                    }
                    .foregroundStyle(k.live ? Color.mintHi : (k.past ? Color.ink4 : Color.ink))

                    if k.live {
                        Text("\(k.s1 - nowMin) min left")
                            .font(.r(11.5, .semibold))
                            .foregroundStyle(Color.mintDim)
                    }
                }
                .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text(k.subject)
                        .font(.r(k.live ? 18 : 16, .semibold))
                        .foregroundStyle(k.past ? Color.ink4 : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(place)
                        .font(.r(14, k.live ? .semibold : .medium))
                        .foregroundStyle(k.live ? Color.mintDim : (k.past ? Color.ink4 : Color.ink3))

                    // A hybrid class has both a room and a join link, so the
                    // button keys off the link rather than off `online`.
                    if !k.past, let raw = k.link, let url = URL(string: raw) {
                        Button { openURL(url) } label: {
                            Text("Join \u{2197}")
                                .font(.r(13.5, .semibold))
                                .foregroundStyle(Color.mintHi)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.mintHi.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .padding(.top, 8)
                    }
                }

                if tappable {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink4)
                        .padding(.top, 3)
                }
            }
            .slab(
                fillFor(k),
                radius: 26,
                pad: EdgeInsets(top: k.live ? 22 : 18, leading: 20, bottom: k.live ? 22 : 18, trailing: 20)
            )
            .contentShape(Rectangle())
            .onTapGesture { if tappable { onTap() } }
        }

        private var place: String {
            let base = k.online ? "Online classroom" : "Room \(k.room ?? "not listed")"
            guard let a = k.att else { return base }
            let b = a.budget
            switch b.state {
            case .empty: return base
            case .short: return base + " · needs \(b.value)"
            case .safe: return base + " · \(b.value) to spare"
            }
        }

        private func fillFor(_ k: Klass) -> Color {
            if k.live { return .surLive }
            if k.past { return .surDim }
            return k.mode == "virtual" ? .surVirtual : .sur
        }
    }
}
