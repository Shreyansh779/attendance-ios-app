import SwiftUI

/// Hero is the room, because that is what you need while walking to it. The
/// number under it is that subject's own slack, not the aggregate — the
/// aggregate is not what stops you skipping a particular class.
struct TodayView: View {
    let day: [Klass]
    let nowMin: Int
    /// Tapping the day strip pins a class; nil means follow the clock.
    @Binding var picked: String?
    let marks: [String: Mark]
    let today: String
    let onMark: (String, String, Bool?) -> Void

    private var hero: Klass? {
        if let id = picked, let k = day.first(where: { $0.id == id }) { return k }
        return day.first(where: { $0.live }) ?? day.first(where: { $0.next })
    }

    var body: some View {
        if let h = hero {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 12)

                Tag(state: tagState(h), virtual: h.mode == "virtual")

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
                    .padding(.top, 22)

                // Answering here is what keeps you off the portal: one tap
                // updates every number without a refresh.
                AttendAsk(
                    klass: h,
                    mark: marks[markKey(h, on: today)],
                    enabled: h.past || h.live,
                    onMark: { onMark(markKey(h, on: today), h.subject, $0) }
                )
                .padding(.top, 10)

                Spacer(minLength: 18)

                DayStrip(day: day, picked: $picked, heroID: hero?.id)
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

    private func tagState(_ k: Klass) -> String {
        if k.live { return "In class now" }
        if k.past { return "Earlier today" }
        return picked != nil && !k.next ? "Later today" : "Up next"
    }

    private func whenText(_ k: Klass) -> String {
        if k.live {
            return "Ends \(hhmm(k.s1))\(ampm(k.s1)), \(k.s1 - nowMin) min left"
        }
        if k.past {
            return "Was \(hhmm(k.s0))\(ampm(k.s0)) to \(hhmm(k.s1))\(ampm(k.s1))"
        }
        let mins = k.s0 - nowMin
        if mins < 60 {
            return "Starts \(hhmm(k.s0))\(ampm(k.s0)), in \(mins) min"
        }
        return "Starts \(hhmm(k.s0))\(ampm(k.s0))"
    }
}

/// Did you attend? Yes adds an attended class, No adds a held one.
private struct AttendAsk: View {
    let klass: Klass
    let mark: Mark?
    let enabled: Bool
    let onMark: (Bool?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let m = mark {
                Text(m.attended ? "Marked attended" : "Marked missed")
                    .font(.r(14.5, .semibold))
                    .foregroundStyle(m.attended ? Color.mintHi : Color.coral)
                Spacer(minLength: 0)
                Button("Undo") { onMark(nil) }
                    .font(.r(14.5, .semibold))
                    .foregroundStyle(Color.ink3)
                    .buttonStyle(.plain)
            } else {
                Text(enabled ? "Did you attend?" : "Not started yet")
                    .font(.r(14.5, .medium))
                    .foregroundStyle(Color.ink2)
                Spacer(minLength: 0)
                if enabled {
                    Pill(text: "Yes", tint: .mintHi) { onMark(true) }
                    Pill(text: "No", tint: .coral) { onMark(false) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sur, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private struct Pill: View {
        let text: String
        let tint: Color
        let act: () -> Void

        var body: some View {
            Button(action: act) {
                Text(text)
                    .font(.r(15, .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(tint.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct Tag: View {
    let state: String
    let virtual: Bool

    private var live: Bool { state == "In class now" }

    var body: some View {
        let ink: Color = live ? (virtual ? Color(0xE58FC0) : .mint) : Color(0x93A0B4)
        HStack(spacing: 8) {
            Circle().fill(ink).frame(width: 7, height: 7)
            Text(state).font(.r(13.5, .semibold))
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
    @Binding var picked: String?
    let heroID: String?

    var body: some View {
        HStack(spacing: 7) {
            ForEach(day) { k in
                Button {
                    // Tapping the class already shown returns to following the
                    // clock, so there is always a way back.
                    picked = (picked == k.id) ? nil : k.id
                } label: {
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
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.mintHi.opacity(k.id == heroID ? 0.9 : 0), lineWidth: 2)
                )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
