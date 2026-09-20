import SwiftUI

/// One subject, in full.
///
/// The attendance list could only ever show a row's headline, and tapping it
/// did nothing — a dead end on a screen that already had a NavigationStack
/// wrapped round it. This is where the rest goes: the whole remaining
/// schedule rather than a count, and the subject's own trend rather than the
/// aggregate one.
struct SubjectView: View {
    let row: AttRow
    let term: Term?
    let blocker: AttRow?
    let history: [Stamp]
    /// This subject's register rows, newest first. Empty until the attendance
    /// search page has been read.
    let daywise: [DaySession]

    private var tint: Color {
        Color.urgencyTint(urgency(of: row, term: term, blocker: blocker))
    }

    /// This subject's percentage on each day the portal was read.
    private var series: [Double] {
        history.compactMap { stamp in
            guard let r = stamp.rows.first(where: { $0.key == row.key }), r.total > 0 else {
                return nil
            }
            return Double(r.attended) / Double(r.total) * 100
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                headline
                if !daywise.isEmpty { register }
                if let tm = term { schedule(tm) }
                if series.count >= 2 { trend }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Backdrop())
        .navigationTitle(row.key)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Where it stands

    private var headline: some View {
        let b = row.budget
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(b.state == .empty ? "—" : (b.state == .short ? "+\(b.value)" : "\(b.value)"))
                    .d(42, .bold)
                    .kerning(-1.0)
                    .foregroundStyle(b.state == .empty ? Color.ink4 : tint)
                    .contentTransition(.numericText())
                Text(caption(b))
                    .r(15, .medium)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Meter(pct: b.state == .empty ? 0 : b.pct, tint: b.state == .empty ? Color.ink4 : tint)
                Text("\(Int(b.pct.rounded()))% · \(row.attended)/\(row.total)")
                    .r(14, .semibold)
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
            }
        }
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }

    private func caption(_ b: Budget) -> String {
        switch b.state {
        case .empty: return "no classes held yet"
        case .short: return "to attend before this clears \(THRESHOLD)%"
        case .safe: return b.value == 0 ? "no room left" : "more you can skip"
        }
    }

    // MARK: - What actually happened

    /// The register, which is the only place that says *which* classes were
    /// missed. Newest first, because the recent ones are the ones in dispute.
    private var register: some View {
        let shown = Array(daywise.sorted { $0.date > $1.date }.prefix(16))
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Day by day")
                    .r(16, .semibold)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                Text("\(daywise.filter(\.present).count) of \(daywise.count)")
                    .r(13, .semibold)
                    .foregroundStyle(Color.ink3)
            }
            VStack(spacing: 9) {
                ForEach(shown, id: \.self) { s in
                    HStack(spacing: 11) {
                        Circle()
                            .fill(s.present ? Color.mintHi : Color.coral)
                            .frame(width: 7, height: 7)
                        Text(shortDate(s.date))
                            .r(13.5, .medium)
                            .foregroundStyle(Color.ink2)
                            .frame(width: 58, alignment: .leading)
                        Text(s.time)
                            .r(13, .medium)
                            .foregroundStyle(Color.ink3)
                        Spacer(minLength: 6)
                        Text(s.present ? "Present" : "Absent")
                            .r(12.5, .semibold)
                            .foregroundStyle(s.present ? Color.mintHi : Color.coral)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if daywise.count > shown.count {
                Text("and \(daywise.count - shown.count) earlier")
                    .r(12.5, .medium)
                    .foregroundStyle(Color.ink4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }

    // MARK: - What is left

    /// One fact: the day this subject stops being something to manage.
    ///
    /// This card used to lead with "45 classes left" and then print all
    /// forty-five dates as chips. The count is the raw material of the answer,
    /// not the answer, and a term's worth of dates is a wall nobody reads.
    @ViewBuilder
    private func schedule(_ tm: Term) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verdict(tm))
                .d(21, .bold)
                .kerning(-0.3)
                .foregroundStyle(tm.reachable ? Color.ink : Color.coral)
                .fixedSize(horizontal: false, vertical: true)
            Text(caveat(tm))
                .r(14, .medium)
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }

    private func verdict(_ tm: Term) -> String {
        if tm.remaining == 0 { return "No classes left" }
        if !tm.reachable { return "\(THRESHOLD)% is out of reach" }
        if let c = tm.clears { return "Clears \(shortDate(c))" }
        return "Already above \(THRESHOLD)%"
    }

    private func caveat(_ tm: Term) -> String {
        if tm.remaining == 0 { return "Nothing left on the timetable for this subject." }
        if !tm.reachable { return "Even attending every one of the classes left." }
        if tm.clears != nil { return "If you attend every class from here." }
        return tm.skippable == 1
            ? "One more can be missed."
            : "\(tm.skippable) more can be missed."
    }

    // MARK: - Which way it is going

    private var trend: some View {
        let delta = (series.last ?? 0) - (series.first ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Since you started tracking")
                .r(16, .semibold)
                .foregroundStyle(Color.ink)
            HStack(spacing: 14) {
                Spark(values: series, tint: delta >= 0 ? Color.mintHi : Color.coral)
                    .frame(height: 34)
                Text(
                    abs(delta) < 0.05
                        ? "flat"
                        : "\(delta >= 0 ? "+" : "−")\(String(format: "%.1f", abs(delta))) pts"
                )
                .r(15, .semibold)
                .foregroundStyle(delta >= 0 ? Color.mintHi : Color.coral)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }
}
