import Foundation
import SwiftUI

struct AttendanceView: View {
    let summary: Summary
    /// Keyed by `AttRow.key`. Empty when the whole term is not known.
    let terms: [String: Term]
    /// Last day of the timetable, when known.
    let termEnd: String?

    var body: some View {
        if summary.subjects.isEmpty {
            Text("No attendance data saved yet.")
                .font(.r(16, .medium))
                .foregroundStyle(Color.ink2)
                .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                .padding(.top, 24)
            Spacer()
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    header.padding(.horizontal, 6).padding(.top, 20).padding(.bottom, 7)

                    // A healthy aggregate can hide one subject that is already
                    // drowning, so name it before the list.
                    if let worst = summary.blocker {
                        Callout(worst: worst, term: terms[worst.key]).padding(.bottom, 6)
                    }

                    ForEach(summary.subjects) { row in
                        SubjectRow(row: row, term: terms[row.key])
                    }
                }
                // Enough for the last card to scroll clear of the home
                // indicator without leaving a visible gap.
                .padding(.bottom, 20)
            }
        }
    }

    private var header: some View {
        let o = summary.overall
        return VStack(alignment: .leading, spacing: 4) {
            Text(o.state == .short ? "+\(o.value) to attend" : "\(o.value) to spare")
                .contentTransition(.numericText())
                .font(.r(27, .bold))
                .kerning(-0.8)
            Text("\(summary.attended) of \(summary.total) attended, \(String(format: "%.1f", o.pct))% overall")
                .font(.r(14.5, .medium))
                .foregroundStyle(Color.ink3)
            if let end = termEnd {
                Text("classes run to \(shortDate(end))")
                    .font(.r(13, .medium))
                    .foregroundStyle(Color.ink4)
            }
        }
    }

    private struct Callout: View {
        let worst: AttRow
        let term: Term?

        /// The first `need` dates, spelled out. Capped, because a fourteen-date
        /// run is a wall of text rather than a plan.
        private func plan(_ tm: Term, need: Int) -> String {
            let take = Array(tm.dates.prefix(need))
            guard !take.isEmpty else { return "" }
            let shown = take.prefix(6).map(shortDate).joined(separator: " · ")
            return take.count > 6
                ? "Starting \(shown) — and \(take.count - 6) more"
                : "That is \(shown)"
        }

        var body: some View {
            let b = worst.budget
            VStack(alignment: .leading, spacing: 10) {
                Text("+\(b.value)")
                    .font(.r(38, .bold))
                    .kerning(-1.5)
                    .foregroundStyle(Color.coral)
                Text(
                    "\(worst.key) is the one holding you back. It needs \(b.value) \(b.value == 1 ? "class" : "classes") in a row to clear \(THRESHOLD)%."
                )
                .font(.r(14.5, .medium))
                .foregroundStyle(Color(0xCBB0A9))
                .fixedSize(horizontal: false, vertical: true)

                // The bit the percentage alone cannot tell you: whether there
                // are even enough classes left to do it in.
                if let tm = term {
                    Text(
                        tm.reachable
                            ? (tm.clears.map {
                                "Attend every one from here and it clears on \(shortDate($0)), with \(tm.remaining) scheduled."
                            } ?? "")
                            : "Only \(tm.remaining) \(tm.remaining == 1 ? "class is" : "classes are") left, so \(THRESHOLD)% is no longer reachable."
                    )
                    .font(.r(13.5, .medium))
                    .foregroundStyle(tm.reachable ? Color.ink2 : Color.coral)
                    .fixedSize(horizontal: false, vertical: true)

                    // "Nine in a row" is a number. These are the nine days.
                    if tm.reachable, b.state == .short, b.value >= 1 {
                        Text(plan(tm, need: b.value))
                            .font(.r(13, .medium))
                            .foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .slab(.surLow, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        }
    }

    private struct SubjectRow: View {
        let row: AttRow
        let term: Term?

        var body: some View {
            let b = row.budget
            let low = b.state == .short
            let idle = b.state == .empty

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.key)
                        .font(.r(16, .semibold))
                        .foregroundStyle(idle ? Color.ink4 : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(idle ? "—" : (low ? "+\(b.value)" : "\(b.value)"))
                        .contentTransition(.numericText())
                        .font(.r(idle ? 15 : (low ? 16 : 22), .bold))
                        .kerning(-0.6)
                        .foregroundStyle(idle ? Color.ink4 : (low ? Color.coral : Color.mintHi))
                        .fixedSize()
                }
                HStack(spacing: 12) {
                    Meter(pct: idle ? 0 : b.pct, low: low)
                    Text(idle ? "not started" : "\(Int(b.pct.rounded()))% · \(row.attended)/\(row.total)")
                        .font(.r(13.5, .medium))
                        .foregroundStyle(Color.ink3)
                        .fixedSize()
                }
                if let tm = term {
                    Text(termLine(b, tm))
                        .font(.r(13, .medium))
                        .foregroundStyle(tm.reachable ? Color.ink4 : Color.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .slab(idle ? .surDim : .sur, radius: 24, pad: EdgeInsets(top: 17, leading: 20, bottom: 17, trailing: 20))
        }
    }
}
