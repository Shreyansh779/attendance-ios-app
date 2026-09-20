import Foundation
import SwiftUI

struct AttendanceView: View {
    let summary: Summary
    /// Keyed by `AttRow.key`. Empty when the whole term is not known.
    let terms: [String: Term]
    /// Oldest first. Empty until the portal has been read on two separate days.
    let history: [Stamp]
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
                                history: history,
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

                VStack(spacing: 9) {
                    ForEach(sessions, id: \.self) { s in
                        HStack(spacing: 11) {
                            Circle()
                                .fill(s.present ? Color.mintHi : Color.coral)
                                .frame(width: 7, height: 7)
                            Text(dayLabel(s.date))
                                .r(13, .semibold)
                                .foregroundStyle(Color.ink2)
                                .frame(width: 46, alignment: .leading)
                            Text(s.subject)
                                .r(14, .medium)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(startOf(s.time))
                                .r(12.5, .medium)
                                .foregroundStyle(Color.ink3)
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(s.subject), \(dayLabel(s.date)), \(s.present ? "present" : "absent")"
                        )
                    }
                }
            }
            .slab(.sur, radius: 26, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        }

        private func dayLabel(_ iso: String) -> String {
            guard let d = Snapshot.isoDay.date(from: iso) else { return iso }
            return d.formatted(.dateTime.weekday(.abbreviated))
        }

        /// "17:00 - 17:55" is two facts and one of them is enough here.
        private func startOf(_ time: String) -> String {
            String(time.split(separator: "-").first ?? "").trimmingCharacters(in: .whitespaces)
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
