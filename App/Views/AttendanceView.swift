import Foundation
import SwiftUI

struct AttendanceView: View {
    let summary: Summary
    /// Keyed by `AttRow.key`. Empty when the whole term is not known.
    let terms: [String: Term]
    /// The register. Empty until the attendance search page has been read.
    let daywise: [DaySession]
    let now: Date

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

                    if !thisWeek.isEmpty {
                        WeekRegister(sessions: thisWeek).padding(.bottom, 6)
                    }

                    ForEach(summary.subjects) { row in
                        NavigationLink {
                            SubjectView(
                                row: row,
                                term: terms[row.key],
                                blocker: summary.blocker,
                                daywise: daywise.filter { $0.subject == row.key }
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

    /// Monday to Sunday, in order. The register is the only source for this:
    /// the timetable says a class was scheduled, not whether you were in it.
    private var thisWeek: [DaySession] {
        let w = Snapshot.week(of: now)
        return daywise
            .filter { $0.date >= w.from && $0.date <= w.to }
            .sorted { ($0.date, $0.time) < ($1.date, $1.time) }
    }

    /// The day the last subject still short of the line gets there.
    ///
    /// Every row already carries its own clear date; the only question the
    /// list cannot answer at a glance is which of them is last, and that is
    /// the day the whole term stops needing to be managed.
    private var allClear: (date: String?, stuck: Int) {
        let short = summary.subjects
            .filter { $0.budget.state == .short }
            .compactMap { terms[$0.key] }
        return (short.compactMap(\.clears).max(), short.filter { !$0.reachable }.count)
    }

    /// The percentage, and the day it stops mattering.
    ///
    /// A "+9 to attend" sat here first, aggregated across every subject. The
    /// number was real and meant nothing: attendance is enforced per subject,
    /// so nine classes spread over the six that are short is not a thing
    /// anybody can act on. The per-subject rows below already say it where it
    /// counts.
    private var header: some View {
        let o = summary.overall
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(String(format: "%.1f", o.pct))%")
                    .contentTransition(.numericText())
                    .d(29, .bold)
                    .kerning(-0.5)
                if allClear.stuck > 0 {
                    Text(
                        allClear.stuck == 1
                            ? "one subject can no longer reach \(THRESHOLD)%"
                            : "\(allClear.stuck) subjects can no longer reach \(THRESHOLD)%"
                    )
                    .r(13.5, .medium)
                    .foregroundStyle(Color.coral)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let d = allClear.date {
                    Text("all clear by \(shortDate(d))")
                        .r(13.5, .medium)
                        .foregroundStyle(Color.ink2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The week you are actually in, one row per class.
    ///
    /// Everything else on this screen is a running total over a whole term,
    /// which is the right frame for planning and the wrong one for "how is it
    /// going". A week is short enough to be a fact rather than a projection.
    private struct WeekRegister: View {
        let sessions: [DaySession]

        private var attended: Int { sessions.filter(\.present).count }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This week")
                        .r(12.5, .semibold)
                        .textCase(.uppercase)
                        .kerning(0.6)
                        .foregroundStyle(Color.ink3)
                    Spacer(minLength: 8)
                    Text("\(attended) of \(sessions.count)")
                        .r(12.5, .semibold)
                        .foregroundStyle(attended == sessions.count ? Color.mintHi : Color.ink2)
                }

                // One row per day, not one per class. Fifteen lines of
                // truncated subject names is a wall, and the question this
                // card answers - how is the week going - is answered by the
                // shape of the bars rather than by reading any of them.
                VStack(spacing: 11) {
                    ForEach(days, id: \.day) { d in
                        HStack(spacing: 12) {
                            Text(dayLabel(d.day))
                                .r(13, .semibold)
                                .foregroundStyle(Color.ink2)
                                .frame(width: 38, alignment: .leading)
                            HStack(spacing: 5) {
                                ForEach(Array(d.items.enumerated()), id: \.offset) { _, s in
                                    Capsule()
                                        .fill(s.present ? Color.mintHi : Color.coral)
                                        .frame(height: 7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            Text("\(d.items.filter(\.present).count)/\(d.items.count)")
                                .r(12.5, .medium)
                                .foregroundStyle(Color.ink3)
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(dayLabel(d.day)), \(d.items.filter(\.present).count) of \(d.items.count) attended"
                        )
                    }
                }
            }
            .slab(.sur, radius: 26, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        }

        private var days: [(day: String, items: [DaySession])] {
            Dictionary(grouping: sessions, by: \.date)
                .sorted { $0.key < $1.key }
                .map { (day: $0.key, items: $0.value.sorted { $0.time < $1.time }) }
        }

        private func dayLabel(_ iso: String) -> String {
            guard let d = Snapshot.isoDay.date(from: iso) else { return iso }
            return d.formatted(.dateTime.weekday(.abbreviated))
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
