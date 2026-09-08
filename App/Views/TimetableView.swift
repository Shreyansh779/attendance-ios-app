import SwiftUI

struct TimetableView: View {
    let day: [Klass]
    let nowMin: Int
    let week: [String: [Session]]
    let rows: [AttRow]

    /// The cached week, today first. Days already gone are dropped: nobody
    /// needs last Tuesday.
    private var upcoming: [(String, [Klass])] {
        let todayKey = Snapshot.isoDay.string(from: Date())
        return week.keys
            .filter { $0 >= todayKey }
            .sorted()
            .compactMap { key in
                let list = shapeDay(
                    sessions: week[key] ?? [],
                    rows: rows,
                    nowMin: key == todayKey ? nowMin : -1
                )
                return list.isEmpty ? nil : (key, list)
            }
    }

    private func heading(_ key: String) -> String {
        guard let d = Snapshot.isoDay.date(from: key) else { return key }
        let todayKey = Snapshot.isoDay.string(from: Date())
        if key == todayKey { return "Today" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    var body: some View {
        if day.isEmpty && upcoming.isEmpty {
            Text("No classes cached yet. Refresh from the portal.")
                .font(.r(16, .medium))
                .foregroundStyle(Color.ink2)
                .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                .padding(.top, 24)
            Spacer()
        } else if upcoming.count > 1 {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(upcoming, id: \.0) { key, list in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(heading(key)).font(.r(21, .bold)).kerning(-0.5)
                            Text("\(list.count) \(list.count == 1 ? "class" : "classes")")
                                .font(.r(13.5, .medium))
                                .foregroundStyle(Color.ink3)
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, key == upcoming.first?.0 ? 18 : 22)
                        .padding(.bottom, 6)

                        ForEach(list) { k in
                            Row(k: k, nowMin: nowMin)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Date().formatted(.dateTime.weekday(.wide)))
                            .font(.r(27, .bold))
                            .kerning(-0.8)
                        Text(subtitle)
                            .font(.r(14.5, .medium))
                            .foregroundStyle(Color.ink3)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 20)
                    .padding(.bottom, 7)

                    ForEach(day) { k in
                        Row(k: k, nowMin: nowMin)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var subtitle: String {
        let left = day.filter { !$0.past }.count
        let noun = day.count == 1 ? "class" : "classes"
        return "\(day.count) \(noun), \(left > 0 ? "\(left) still to come" : "all done")"
    }

    private struct Row: View {
        @Environment(\.openURL) private var openURL

        let k: Klass
        let nowMin: Int

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

                    if k.online, !k.past, let raw = k.link, let url = URL(string: raw) {
                        Button { openURL(url) } label: {
                            Text("Join \u{2197}")
                                .font(.r(13.5, .semibold))
                                .foregroundStyle(Color.mintHi)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.mintHi.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
            }
            .slab(
                fillFor(k),
                radius: 26,
                pad: EdgeInsets(top: k.live ? 22 : 18, leading: 20, bottom: k.live ? 22 : 18, trailing: 20)
            )
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
