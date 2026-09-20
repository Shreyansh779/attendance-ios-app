import SwiftUI

/// Hero is the room, because that is what you need while walking to it. The
/// number under it is that subject's own slack, not the aggregate — the
/// aggregate is not what stops you skipping a particular class.
struct TodayView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let day: [Klass]
    let nowMin: Int
    /// Keyed by `AttRow.key`. Empty when the whole term is not known.
    let terms: [String: Term]
    /// The subject gating everything, so only it gets the loudest colour.
    let blocker: AttRow?
    /// Tomorrow's classes, shown once today is done — at which point "what is
    /// next" is the only question left, and the screen was otherwise empty.
    let tomorrow: [Klass]
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
        // The strip lives outside the hero branch on purpose. It used to be
        // inside it, so the moment the last class ended `hero` went nil, the
        // strip disappeared, and the day became unmarkable - at exactly the
        // point you would sit down to mark it.
        VStack(alignment: .leading, spacing: 0) {
            if let h = hero {
                Tag(state: tagState(h), virtual: h.mode == "virtual")
                    .padding(.top, 12)

                Text(h.online ? "Online" : (h.room ?? "No room"))
                    .d(h.online ? 48 : 84, .bold)
                    // A serif needs far less negative tracking than a rounded
                    // sans: the serifs themselves do the joining up, and
                    // pulling them together closes the counters.
                    .kerning(h.online ? -1.0 : -2.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.top, 20)
                    // Otherwise VoiceOver reads "11213" with no idea what it is.
                    .accessibilityLabel(h.online ? "Online class" : "Room \(h.room ?? "not listed")")

                Text(h.subject)
                    .r(20, .regular)
                    .foregroundStyle(Color.ink2)
                    .lineSpacing(2)
                    .padding(.top, 20)

                if h.online, let raw = h.link, let url = URL(string: raw) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Join the class").r(15.5, .semibold)
                            Text("\u{2197}").r(15, .semibold)
                        }
                        .foregroundStyle(Color.onInk)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(Color.ink, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 14)
                }

                Text(whenText(h))
                    .r(16, .medium)
                    .foregroundStyle(Color.ink3)
                    .padding(.top, 9)

                OwnSlack(att: h.att, term: h.att.flatMap { terms[$0.key] }, blocker: blocker)
                    .padding(.top, 22)

                // Answering here is what keeps you off the portal: one tap
                // updates every number without a refresh.
                AttendAsk(
                    klass: h,
                    mark: marks[markKey(h, on: today)],
                    // With no matching attendance row applyMarks drops the mark
                    // on the floor, so don't offer a tick that moves no number.
                    enabled: (h.past || h.live) && h.att != nil,
                    note: h.att == nil
                        ? "No matching subject to tick off"
                        : (h.past || h.live ? "Did you attend?" : "Not started yet"),
                    onMark: { onMark(markKey(h, on: today), h.subject, $0) }
                )
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(doneText)
                        .r(16, .medium)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .slab(.sur, radius: 28, pad: EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22))

                    if !tomorrow.isEmpty { Tomorrow(day: tomorrow) }
                }
                .padding(.top, 12)
            }

            Spacer(minLength: 18)

            if !day.isEmpty {
                DayStrip(day: day, picked: $picked, heroID: hero?.id, marks: marks, today: today)
            }
        }
        .padding(.bottom, 20)
        .animation(Motion.ui.reduced(reduceMotion), value: hero?.id)
    }

    /// How the day ended, including how much of it is still unticked - the
    /// number is the reason to look at the strip below.
    private var doneText: String {
        guard !day.isEmpty else { return "No classes listed for today." }
        let markable = day.filter { $0.att != nil }.count
        let ticked = day.filter { marks[markKey($0, on: today)] != nil }.count
        if markable == 0 { return "That was the last class for today." }
        if ticked >= markable { return "That was the last class. All \(ticked) ticked off." }
        return "That was the last class. \(markable - ticked) still to tick off below."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shown when nothing is marked yet: the prompt, or why there isn't one.
    let note: String
    let onMark: (Bool?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let m = mark {
                Text(m.attended ? "Marked attended" : "Marked missed")
                    .r(14.5, .semibold)
                    .foregroundStyle(m.attended ? Color.mintHi : Color.coral)
                Spacer(minLength: 0)
                Button("Undo") { onMark(nil) }
                    .r(14.5, .semibold)
                    .foregroundStyle(Color.ink3)
                    .buttonStyle(.pressable)
            } else {
                Text(note)
                    .r(14.5, .medium)
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
        .glassy(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(Motion.ui.reduced(reduceMotion), value: mark)
    }

    private struct Pill: View {
        let text: String
        let tint: Color
        let act: () -> Void

        var body: some View {
            Button(action: act) {
                Text(text)
                    .r(15, .semibold)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .glassy(Capsule(), tint: tint.opacity(0.15), soft: false)
            }
            .buttonStyle(.pressable)
        }
    }
}

/// Tomorrow at a glance: when it starts, where, and how much of it there is.
private struct Tomorrow: View {
    let day: [Klass]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tomorrow")
                .r(12.5, .semibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(Color.ink3)

            if let first = day.first {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(hhmm(first.s0))
                        .d(34, .bold)
                        .kerning(-0.8)
                    Text(ampm(first.s0))
                        .r(15, .semibold)
                        .foregroundStyle(Color.ink3)
                }
                Text(first.subject)
                    .r(17, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(first.online ? "Online classroom" : "Room \(first.room ?? "not listed")")
                    .r(14, .medium)
                    .foregroundStyle(Color.ink3)
            }

            Text(day.count == 1 ? "1 class" : "\(day.count) classes")
                .r(13.5, .medium)
                .foregroundStyle(Color.ink4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }
}

private struct Tag: View {
    let state: String
    let virtual: Bool

    private var live: Bool { state == "In class now" }

    var body: some View {
        let ink: Color = live ? (virtual ? Color.violet : .mint) : Color.ink3
        HStack(spacing: 8) {
            Circle().fill(ink).frame(width: 7, height: 7)
            Text(state).r(13.5, .semibold)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(live ? .regular.tint(Color.surLive) : .regular, in: .capsule)
    }
}

/// This class's own room to skip — the number you actually weigh.
private struct OwnSlack: View {
    let att: AttRow?
    let term: Term?
    let blocker: AttRow?

    var body: some View {
        if let a = att {
            let b = a.budget
            let low = b.state == .short
            let tint = Color.urgencyTint(urgency(of: a, term: term, blocker: blocker))
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(b.state == .empty ? "—" : (low ? "+\(b.value)" : "\(b.value)"))
                        .contentTransition(.numericText())
                        .d(36, .bold)
                        .kerning(-0.8)
                        .foregroundStyle(tint)
                    Text(caption(b))
                        .r(14.5, .medium)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Meter(pct: b.pct, tint: b.state == .empty ? Color.ink4 : tint)
                    Text("\(Int(b.pct.rounded()))% · \(a.attended)/\(a.total)")
                        .r(14, .semibold)
                        .foregroundStyle(Color.ink2)
                        .fixedSize()
                }
                if let tm = term {
                    Text(termLine(b, tm))
                        .r(13.5, .medium)
                        .foregroundStyle(tm.reachable ? Color.ink3 : Color.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .slab(.sur, radius: 28, pad: EdgeInsets(top: 19, leading: 22, bottom: 19, trailing: 22))
        } else {
            Text("No attendance row matches this class.")
                .r(14.5, .medium)
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
    /// So you can see at a glance which classes are already ticked off,
    /// instead of opening each one to find out.
    let marks: [String: Mark]
    let today: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(day) { k in
                Button {
                    // Tapping the class already shown returns to following the
                    // clock, so there is always a way back.
                    picked = (picked == k.id) ? nil : k.id
                } label: {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        if let m = marks[markKey(k, on: today)] {
                            Circle()
                                .fill(m.attended ? Color.mintHi : Color.coral)
                                .frame(width: 5, height: 5)
                        }
                        Text(hhmm(k.s0))
                            .d(14, .bold)
                            .kerning(-0.2)
                    }
                    .foregroundStyle(k.live ? Color.mintHi : (k.past ? Color.ink4 : Color.ink))
                    Text(k.online ? "online" : (k.room ?? "—"))
                        .r(11, .medium)
                        .foregroundStyle(k.live ? Color.mintDim : (k.past ? Color.ink4 : Color.ink3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 4)
                .glassy(
                    RoundedRectangle(cornerRadius: 20, style: .continuous),
                    tint: k.live ? Color.surLive : (k.past ? Color.surDim : Color.sur),
                    soft: false
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.ink.opacity(k.id == heroID ? 0.85 : 0), lineWidth: 1.5)
                )
                }
                .buttonStyle(.pressableCard)
                .accessibilityLabel(
                    "\(k.subject), \(hhmm(k.s0))\(ampm(k.s0)), "
                        + (k.online ? "online" : (k.room.map { "room " + $0 } ?? "no room"))
                )
            }
        }
        // Pinning a class is a selection, not a commit.
        .sensoryFeedback(.selection, trigger: picked)
    }
}
