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

    // MARK: - What is left

    @ViewBuilder
    private func schedule(_ tm: Term) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tm.remaining == 0 ? "Nothing left" : "\(tm.remaining) classes left")
                .r(16, .semibold)
                .foregroundStyle(Color.ink)

            if !tm.reachable, tm.remaining > 0 {
                Text("Even attending every one, \(THRESHOLD)% is no longer reachable.")
                    .r(14, .medium)
                    .foregroundStyle(Color.coral)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let c = tm.clears {
                Text("Attend every one and it clears on \(shortDate(c)).")
                    .r(14, .medium)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tm.skippable > 0 {
                Text("\(tm.skippable) of them can be missed.")
                    .r(14, .medium)
                    .foregroundStyle(Color.ink2)
            }

            // The whole run, not a count. The point of holding the term is
            // being able to say which days, and a date you can look at is a
            // plan in a way that "nine in a row" never is.
            if !tm.dates.isEmpty {
                let needed = row.budget.state == .short ? row.budget.value : 0
                FlowDates(dates: tm.dates, highlightFirst: needed, tint: tint)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
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

/// The remaining dates as wrapping chips, with the ones that actually get you
/// over the line picked out.
private struct FlowDates: View {
    let dates: [String]
    let highlightFirst: Int
    let tint: Color

    var body: some View {
        // A plain wrapping run of chips. Capped, because a full term is
        // thirty-odd dates and nobody reads the thirtieth.
        let shown = Array(dates.prefix(18))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: shown.count, by: 3)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(shown[start..<min(start + 3, shown.count)], id: \.self) { d in
                        let idx = shown.firstIndex(of: d) ?? 0
                        let key = idx < highlightFirst
                        Text(shortDate(d))
                            .r(12.5, key ? .semibold : .medium)
                            .foregroundStyle(key ? Color.onAccent : Color.ink3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassy(Capsule(), tint: key ? tint : Color.surDim, soft: false)
                    }
                    Spacer(minLength: 0)
                }
            }
            if dates.count > shown.count {
                Text("and \(dates.count - shown.count) more")
                    .r(12.5, .medium)
                    .foregroundStyle(Color.ink4)
            }
        }
    }
}
