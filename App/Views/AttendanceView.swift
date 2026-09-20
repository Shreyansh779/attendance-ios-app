import Foundation
import SwiftUI

struct AttendanceView: View {
    let summary: Summary
    /// Keyed by `AttRow.key`. Empty when the whole term is not known.
    let terms: [String: Term]
    /// Oldest first. Empty until the portal has been read on two separate days.
    let history: [Stamp]

    var body: some View {
        if summary.subjects.isEmpty {
            Text("No attendance data saved yet.")
                .r(16, .medium)
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
                        NavigationLink {
                            SubjectView(
                                row: row,
                                term: terms[row.key],
                                blocker: summary.blocker,
                                history: history
                            )
                        } label: {
                            SubjectRow(row: row, term: terms[row.key], blocker: summary.blocker)
                        }
                        .buttonStyle(.pressableCard)
                    }
                }
                // Enough for the last card to scroll clear of the home
                // indicator without leaving a visible gap.
                .padding(.bottom, 20)
            }
        }
    }

    /// Which way it is going, and by how much, since the first reading kept.
    ///
    /// Nil until there are two days of history: one point is not a direction,
    /// and drawing a flat line from a single reading would imply otherwise.
    private var trend: (series: [Double], delta: Double, label: String)? {
        let usable = history.filter { $0.total > 0 }
        guard usable.count >= 2, let first = usable.first, let last = usable.last else { return nil }
        let delta = last.pct - first.pct
        let since = shortDate(first.day)
        let word = delta >= 0.05 ? "up" : (delta <= -0.05 ? "down" : "flat")
        let label = word == "flat"
            ? "flat since \(since)"
            : "\(word) \(String(format: "%.1f", abs(delta))) points since \(since)"
        return (usable.map(\.pct), delta, label)
    }

    /// Two numbers and a direction. Everything else that used to live here -
    /// the raw 105-of-144, the term end date - was arithmetic the screen had
    /// already done for you, printed again underneath.
    private var header: some View {
        let o = summary.overall
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(o.state == .short ? "+\(o.value) to attend" : "\(o.value) to spare")
                    .contentTransition(.numericText())
                    .d(29, .bold)
                    .kerning(-0.5)
                if let t = trend {
                    HStack(spacing: 9) {
                        Spark(values: t.series, tint: t.delta >= 0 ? Color.mintHi : Color.coral)
                            .frame(width: 52, height: 14)
                        Text(t.label)
                            .r(13, .medium)
                            .foregroundStyle(t.delta >= 0 ? Color.mintHi : Color.coral)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("\(String(format: "%.1f", o.pct))%")
                .r(15, .semibold)
                .foregroundStyle(Color.ink2)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .glassy(Capsule(), soft: false)
                .fixedSize()
        }
    }

    /// The subject in the way, as a shape rather than as a paragraph.
    ///
    /// This card used to be four sentences of prose - the subject name, the
    /// count, the clear date and the run of dates, each spelled out in full.
    /// Nobody reads four sentences on a screen they open to check one number.
    /// It is now a label, a number, a bar and a row of dates: the same facts,
    /// none of them in a sentence.
    private struct Callout: View {
        let worst: AttRow
        let term: Term?

        var body: some View {
            let b = worst.budget
            VStack(alignment: .leading, spacing: 13) {
                Text(worst.key)
                    .r(12.5, .semibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(Color.coral)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("+\(b.value)")
                        .d(40, .bold)
                        .kerning(-1.0)
                        .foregroundStyle(Color.coral)
                    Text("in a row to clear \(THRESHOLD)%")
                        .r(14.5, .medium)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Meter(pct: b.pct, tint: Color.coral)
                    Text("\(Int(b.pct.rounded()))% · \(worst.attended)/\(worst.total)")
                        .r(13.5, .semibold)
                        .foregroundStyle(Color.ink2)
                        .fixedSize()
                }

                if let tm = term {
                    if tm.reachable {
                        // The dates you have to turn up to, picked out of the
                        // ones that follow. A date you can look at is a plan in
                        // a way that "seven in a row" never is.
                        if b.state == .short, b.value >= 1, !tm.dates.isEmpty {
                            Chips(dates: tm.dates, need: b.value)
                        }
                        if let c = tm.clears {
                            Label("Clears \(shortDate(c))", systemImage: "checkmark.circle")
                                .r(13, .semibold)
                                .foregroundStyle(Color.ink3)
                        }
                    } else {
                        Label(
                            "\(THRESHOLD)% is out of reach - only \(tm.remaining) left",
                            systemImage: "exclamationmark.triangle"
                        )
                        .r(13, .semibold)
                        .foregroundStyle(Color.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .slab(.surLow, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        }

        /// The next few dates, the required ones filled in.
        private struct Chips: View {
            let dates: [String]
            let need: Int

            var body: some View {
                let shown = Array(dates.prefix(Swift.min(Swift.max(need, 1), 7)))
                HStack(spacing: 5) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, d in
                        Text(shortDate(d))
                            .r(11.5, .semibold)
                            .foregroundStyle(i < need ? Color.onInk : Color.ink3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                i < need ? Color.ink : Color.clear,
                                in: Capsule()
                            )
                    }
                    if dates.count > shown.count, need > shown.count {
                        Text("+\(need - shown.count)")
                            .r(11.5, .semibold)
                            .foregroundStyle(Color.ink3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private struct SubjectRow: View {
        let row: AttRow
        let term: Term?
        let blocker: AttRow?

        var body: some View {
            let b = row.budget
            let low = b.state == .short
            let idle = b.state == .empty
            let tint = Color.urgencyTint(urgency(of: row, term: term, blocker: blocker))

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.key)
                        .p(16, .semibold)
                        .foregroundStyle(idle ? Color.ink4 : Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(idle ? "—" : (low ? "+\(b.value)" : "\(b.value)"))
                        .contentTransition(.numericText())
                        .r(idle ? 16 : (low ? 18 : 23), .bold)
                        .kerning(-0.4)
                        .foregroundStyle(idle ? Color.ink4 : tint)
                        .fixedSize()
                }
                HStack(spacing: 12) {
                    Meter(pct: idle ? 0 : b.pct, tint: idle ? Color.ink4 : tint)
                    Text(idle ? "not started" : "\(Int(b.pct.rounded()))% · \(row.attended)/\(row.total)")
                        .r(13.5, .medium)
                        .foregroundStyle(Color.ink3)
                        .fixedSize()
                }
                if let tm = term {
                    Text(termLine(b, tm))
                        .r(13, .medium)
                        .foregroundStyle(tm.reachable ? Color.ink4 : Color.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .slab(idle ? .surDim : .sur, radius: 24, pad: EdgeInsets(top: 17, leading: 20, bottom: 17, trailing: 20))
        }
    }
}
