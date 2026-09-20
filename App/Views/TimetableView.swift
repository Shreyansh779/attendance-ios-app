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
    /// What has already been ticked off, and how to tick.
    let marks: [String: Mark]
    let onMark: (String, String, Bool?) -> Void
    /// Days the university is shut. The feed still lists classes on some of
    /// them, and showing those would be a lie about the day.
    let holidays: [Holiday]

    private var holidayToday: Holiday? {
        holidays.first { $0.from <= selectedKey && selectedKey <= $0.to }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Days from today. Negative is the past, which is the whole point of
    /// letting it go backwards: a class you missed on Tuesday is only
    /// markable if you can still navigate to Tuesday.
    @State private var offset = 0

    /// A fortnight forward, a week back. Forward is capped because paging
    /// through a whole term one arrow at a time is not a timetable; backward
    /// is capped because `week` only keeps what past refreshes happened to
    /// leave behind.
    /// The date picker, for when paging one day at a time is the wrong tool.
    @State private var picking = false

    private var bounds: (min: Int, max: Int) {
        let cal = Calendar.current
        guard let base = Snapshot.isoDay.date(from: today) else { return (0, 0) }
        // Backwards is always open. It used to require the day to be cached
        // already, but the scrape only ever returns today onwards, so a past
        // day is only there if you happened to refresh on it - meaning a fresh
        // install had the arrow permanently disabled. A day with nothing
        // cached says so; a dead control says nothing.
        var hi = 0
        for d in 0...13 {
            guard let date = cal.date(byAdding: .day, value: d, to: base) else { continue }
            if week[Snapshot.isoDay.string(from: date)] != nil { hi = Swift.max(hi, d) }
        }
        // Sixty, matching how far back the scrape now keeps days.
        return (-60, hi)
    }

    private var selectedKey: String {
        guard let base = Snapshot.isoDay.date(from: today),
            let d = Calendar.current.date(byAdding: .day, value: offset, to: base)
        else { return today }
        return Snapshot.isoDay.string(from: d)
    }

    /// Marking a class that has not happened yet is nonsense, so the swipe is
    /// only offered on days that are done or under way.
    private func markable(_ k: Klass) -> Bool {
        guard k.att != nil else { return false }
        if offset < 0 { return true }
        if offset > 0 { return false }
        return k.past || k.live
    }

    private var list: [Klass] {
        let sessions = week[selectedKey] ?? []
        if sessions.isEmpty && selectedKey == today { return day }
        // -1 means "nothing has happened yet", which is right for a future day
        // and wrong for a past one - it rendered yesterday's finished classes
        // as upcoming, complete with Join buttons. A past day is entirely over.
        let clock: Int
        if offset == 0 { clock = nowMin } else if offset < 0 { clock = 24 * 60 } else { clock = -1 }
        return shapeDay(sessions: sessions, rows: rows, nowMin: clock)
    }

    var body: some View {
        content
            .animation(Motion.ui.reduced(reduceMotion), value: offset)
            // A refresh can drop days off either end; keep the page inside them.
            .onChange(of: bounds.min) { _, lo in offset = Swift.max(offset, lo) }
            .onChange(of: bounds.max) { _, hi in offset = Swift.min(offset, hi) }
            .sheet(isPresented: $picking) {
                DayPicker(today: today, offset: $offset)
                    .presentationDetents([.medium])
                    .presentationBackground(.regularMaterial)
            }
    }

    /// A scroll view at the root, with the stepper as its first row.
    ///
    /// The stepper was pinned as a top safe-area inset, which put it above the
    /// large title: scrolling then slid "Timetable" down underneath the date,
    /// which is backwards. A navigation bar wants the scroll view to own
    /// everything below it, so the stepper scrolls away like anything else.
    @ViewBuilder
    private var content: some View {
        if let h = holidayToday {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    nav
                    VStack(alignment: .leading, spacing: 6) {
                        Text(h.name)
                            .d(23, .bold)
                            .kerning(-0.3)
                        Text(h.type.isEmpty ? "No classes" : h.type)
                            .r(14, .medium)
                            .foregroundStyle(Color.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .slab(.sur, radius: 28, pad: EdgeInsets(top: 24, leading: 22, bottom: 24, trailing: 22))
                }
            }
        } else if list.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    nav
                    Text(
                        offset < 0 && week[selectedKey] == nil
                            ? "Nothing cached for this day. Days are stored as you refresh."
                            : "No classes this day."
                    )
                    .p(16)
                    .foregroundStyle(Color.ink2)
                    .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                }
            }
        } else {
                // A real List, so rows get swipe actions - which is the native
                // answer to "how do I tick off a class I already attended"
                // rather than a custom control invented for the purpose.
                List {
                    nav
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 12, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(list) { k in
                        Row(
                            k: k, nowMin: nowMin,
                            tappable: selectedKey == today,
                            mark: marks[markKey(k, on: selectedKey)],
                            onTap: { onOpenToday(k.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 5, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if markable(k) {
                                Button {
                                    onMark(markKey(k, on: selectedKey), k.subject, false)
                                } label: {
                                    Label("Missed", systemImage: "xmark")
                                }
                                .tint(Color.coral)

                                Button {
                                    onMark(markKey(k, on: selectedKey), k.subject, true)
                                } label: {
                                    Label("Attended", systemImage: "checkmark")
                                }
                                .tint(Color.mintHi)
                            }
                            if marks[markKey(k, on: selectedKey)] != nil {
                                Button {
                                    onMark(markKey(k, on: selectedKey), k.subject, nil)
                                } label: {
                                    Label("Clear", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Color.ink4)
                            }
                        }
                    }
                }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// One capsule of glass: back a day, which day, forward a day - and, when
    /// you have wandered off, one tap back to today. The date itself opens the
    /// picker, since it is the biggest target on the row and already names
    /// exactly what tapping it would change.
    private var nav: some View {
        HStack(spacing: 4) {
            arrow("chevron.left", enabled: offset > bounds.min) { offset -= 1 }

            Button { picking = true } label: {
                Text(selectedKey == today ? "Today · \(dateLabel)" : dateLabel)
                    .r(16, .semibold)
                    .foregroundStyle(selectedKey == today ? Color.ink : Color.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Pick a date")

            if offset != 0 {
                Button {
                    withAnimation(Motion.ui.reduced(reduceMotion)) { offset = 0 }
                } label: {
                    Text("Today")
                        .r(13, .semibold)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .glassy(Capsule(), soft: false)
                }
                .buttonStyle(.pressable)
                .transition(.soft)
            }

            arrow("chevron.right", enabled: offset < bounds.max) { offset += 1 }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .glassy(Capsule(), tint: .well, material: .ultraThinMaterial)
    }

    private func arrow(_ system: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Color.ink : Color.ink4)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .accessibilityLabel(label(for: system))
    }

    private func label(for system: String) -> String {
        system == "chevron.left" ? "Previous day" : "Next day"
    }

    private var dateLabel: String {
        guard let d = Snapshot.isoDay.date(from: selectedKey) else { return selectedKey }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private struct Row: View {
        @Environment(\.openURL) private var openURL

        let k: Klass
        let nowMin: Int
        let tappable: Bool
        /// Shown as a dot, so a marked class is obvious without opening it.
        let mark: Mark?
        let onTap: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    // fixedSize, because 58pt fitted "8:00 am" and "3:00 pm"
                    // but not "11:00 am" - which wrapped to "11:0 / 0 am" on
                    // every 11 o'clock class.
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if let m = mark {
                            Circle()
                                .fill(m.attended ? Color.mintHi : Color.coral)
                                .frame(width: 5, height: 5)
                        }
                        Text(hhmm(k.s0)).r(17, .bold).kerning(-0.3)
                        Text(ampm(k.s0)).r(11.5, .semibold).foregroundStyle(Color.ink3)
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(k.live ? Color.mintHi : (k.past ? Color.ink4 : Color.ink))

                    if k.live {
                        Text("\(k.s1 - nowMin) min left")
                            .r(11.5, .semibold)
                            .foregroundStyle(Color.mintDim)
                    }
                }
                .frame(width: 70, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text(k.subject)
                        .p(k.live ? 18 : 16, .semibold)
                        .foregroundStyle(k.past ? Color.ink4 : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(place)
                        .r(14, k.live ? .semibold : .medium)
                        .foregroundStyle(k.live ? Color.mintDim : (k.past ? Color.ink4 : Color.ink3))

                    // A hybrid class has both a room and a join link, so the
                    // button keys off the link rather than off `online`.
                    if !k.past, let raw = k.link, let url = URL(string: raw) {
                        Button { openURL(url) } label: {
                            Text("Join \u{2197}")
                                .r(13.5, .semibold)
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .glassy(Capsule(), soft: false)
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

/// Any day, rather than one arrow at a time.
///
/// Days the scrape never reached will say so when you land on them - which is
/// a better answer than a disabled control that explains nothing.
private struct DayPicker: View {
    let today: String
    @Binding var offset: Int
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.ink)
                .padding(.horizontal, 12)
                .navigationTitle("Go to a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { date = Date(); commit() }
                            .foregroundStyle(Color.ink)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { commit() }
                            .foregroundStyle(Color.ink)
                    }
                }
        }
        .onAppear {
            guard let base = Snapshot.isoDay.date(from: today),
                let d = Calendar.current.date(byAdding: .day, value: offset, to: base)
            else { return }
            date = d
        }
    }

    private func commit() {
        let cal = Calendar.current
        if let base = Snapshot.isoDay.date(from: today) {
            let a = cal.startOfDay(for: base)
            let b = cal.startOfDay(for: date)
            offset = cal.dateComponents([.day], from: a, to: b).day ?? offset
        }
        dismiss()
    }
}
