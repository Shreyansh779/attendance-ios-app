import SwiftUI

/// Hero is the room, because that is what you need while walking to it. The
/// number under it is that subject's own slack, not the aggregate — the
/// aggregate is not what stops you skipping a particular class.
struct TodayView: View {
    let day: [Klass]
    let nowMin: Int

    private var hero: Klass? {
        day.first(where: { $0.live }) ?? day.first(where: { $0.next })
    }

    var body: some View {
        if let h = hero {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                Tag(live: h.live, virtual: h.mode == "virtual")

                Text(h.online ? "Online" : (h.room ?? "No room"))
                    .font(.r(h.online ? 52 : 92, .bold))
                    .kerning(h.online ? -1.6 : -4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.top, 20)

                Text(h.subject)
                    .font(.r(21, .medium))
                    .lineSpacing(2)
                    .padding(.top, 20)

                Text(whenText(h))
                    .font(.r(16, .medium))
                    .foregroundStyle(Color.ink3)
                    .padding(.top, 9)

                OwnSlack(att: h.att)
                    .padding(.top, 26)

                Spacer(minLength: 22)

                DayStrip(day: day)
            }
        } else {
            VStack {
                Spacer()
                Text(
                    day.isEmpty
                        ? "No classes listed for today."
                        : "That was the last class for today. Nothing left to walk to."
                )
                .font(.r(16, .medium))
                .foregroundStyle(Color.ink2)
                .slab(.sur, radius: 28, pad: EdgeInsets(top: 26, leading: 24, bottom: 26, trailing: 24))
                Spacer()
            }
        }
    }

    private func whenText(_ k: Klass) -> String {
        if k.live {
            return "Ends \(hhmm(k.s1))\(ampm(k.s1)), \(k.s1 - nowMin) min left"
        }
        let mins = k.s0 - nowMin
        if mins < 60 {
            return "Starts \(hhmm(k.s0))\(ampm(k.s0)), in \(mins) min"
        }
        return "Starts \(hhmm(k.s0))\(ampm(k.s0))"
    }
}

private struct Tag: View {
    let live: Bool
    let virtual: Bool

    var body: some View {
        let ink: Color = live ? (virtual ? Color(0xE58FC0) : .mint) : Color(0x93A0B4)
        HStack(spacing: 8) {
            Circle().fill(ink).frame(width: 7, height: 7)
            Text(live ? "In class now" : "Up next").font(.r(13.5, .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(live ? Color.surLive : Color(0x232833), in: Capsule())
    }
}

/// This class's own room to skip — the number you actually weigh.
private struct OwnSlack: View {
    let att: AttRow?

    var body: some View {
        if let a = att {
            let b = a.budget
            let low = b.state == .short
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(b.state == .empty ? "—" : (low ? "+\(b.value)" : "\(b.value)"))
                        .font(.r(34, .bold))
                        .kerning(-1.3)
                        .foregroundStyle(low ? Color.coral : Color.mintHi)
                    Text(caption(b))
                        .font(.r(14.5, .medium))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Meter(pct: b.pct, low: low)
                    Text("\(Int(b.pct.rounded()))% · \(a.attended)/\(a.total)")
                        .font(.r(14, .semibold))
                        .foregroundStyle(Color.ink2)
                        .fixedSize()
                }
            }
            .slab(.sur, radius: 28, pad: EdgeInsets(top: 19, leading: 22, bottom: 19, trailing: 22))
        } else {
            Text("No attendance row matches this class.")
                .font(.r(14.5, .medium))
                .foregroundStyle(Color.ink2)
                .slab(.sur, radius: 28, pad: EdgeInsets(top: 19, leading: 22, bottom: 19, trailing: 22))
        }
    }

    private func caption(_ b: Budget) -> String {
        switch b.state {
        case .empty: return "no classes held in this subject yet"
        case .short: return "to attend before this subject clears \(THRESHOLD)%"
        case .safe:
            return b.value == 0 ? "no room left in this subject" : "more you can skip in this subject"
        }
    }
}

private struct DayStrip: View {
    let day: [Klass]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(day) { k in
                VStack(spacing: 5) {
                    Text(hhmm(k.s0))
                        .font(.r(13.5, .bold))
                        .kerning(-0.3)
                        .foregroundStyle(k.live ? Color.mintHi : (k.past ? Color.ink4 : Color.ink))
                    Text(k.online ? "online" : (k.room ?? "—"))
                        .font(.r(11, .medium))
                        .foregroundStyle(k.live ? Color.mintDim : (k.past ? Color.ink4 : Color.ink3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 4)
                .background(
                    k.live ? Color.surLive : (k.past ? Color.surDim : Color.sur),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
        }
    }
}
