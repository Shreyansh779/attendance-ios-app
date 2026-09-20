import Foundation

let THRESHOLD = 75

// MARK: - Attendance arithmetic

/// How much room a subject has, in whole classes.
///
/// Integer arithmetic throughout, so no rounding error can shift an answer by
/// one class. `a` = attended, `t` = held, `T` = required percent.
///
///     miss n more:     a/(t+n)     >= T/100  =>  n <= (100a - T*t) / T
///     attend m more:  (a+m)/(t+m)  >= T/100  =>  m >= (T*t - 100a) / (100 - T)
struct Budget {
    enum State { case safe, short, empty }

    let state: State
    /// Classes skippable when `safe`, classes needed when `short`.
    let value: Int
    let pct: Double

    init(attended a: Int, total t: Int, threshold T: Int = THRESHOLD) {
        guard t > 0 else {
            state = .empty
            value = 0
            pct = 0
            return
        }
        pct = Double(a) / Double(t) * 100

        let spare = (a * 100 - T * t) / T
        // Swift truncates toward zero, so a negative quotient needs flooring by
        // hand or the "how many can I skip" answer comes out one too generous.
        let floored = (a * 100 - T * t) < 0 && (a * 100 - T * t) % T != 0 ? spare - 1 : spare

        if floored >= 0 {
            state = .safe
            value = floored
        } else {
            state = .short
            let num = T * t - a * 100
            let den = 100 - T
            value = num / den + (num % den == 0 ? 0 : 1)  // ceil
        }
    }
}

// MARK: - Rows off the page

struct AttRow: Codable, Identifiable, Hashable {
    let key: String
    let attended: Int
    let total: Int

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, attended, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The scraper emits both `key` and `subject`; `key` is the disambiguated
        // one, so prefer it and fall back rather than failing to decode.
        key = (try? c.decode(String.self, forKey: .key)) ?? "Subject"
        attended = (try? c.decode(Int.self, forKey: .attended)) ?? 0
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
    }

    init(key: String, attended: Int, total: Int) {
        self.key = key
        self.attended = attended
        self.total = total
    }

    var budget: Budget { Budget(attended: attended, total: total) }
}

struct Session: Codable, Identifiable, Hashable {
    let subject: String
    let start: String
    let end: String
    let room: String?
    let online: Bool
    let mode: String
    /// ISO yyyy-MM-dd. Only the weekly scrape sets this; the dashboard card is
    /// always today.
    let date: String?
    /// Join URL for an online class, when the portal exposes one.
    let link: String?

    var id: String { (date ?? "") + start + subject }

    enum CodingKeys: String, CodingKey { case subject, start, end, room, online, mode, date, link }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? "Class"
        start = (try? c.decode(String.self, forKey: .start)) ?? ""
        end = (try? c.decode(String.self, forKey: .end)) ?? ""
        room = try? c.decodeIfPresent(String.self, forKey: .room)
        online = (try? c.decode(Bool.self, forKey: .online)) ?? false
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "class"
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        link = try? c.decodeIfPresent(String.self, forKey: .link)
    }

    init(
        subject: String, start: String, end: String,
        room: String?, online: Bool, mode: String,
        date: String? = nil, link: String? = nil
    ) {
        self.subject = subject
        self.start = start
        self.end = end
        self.room = room
        self.online = online
        self.mode = mode
        self.date = date
        self.link = link
    }
}

// MARK: - Times

/// "09:00 AM" -> minutes since midnight.
func toMinutes(_ t: String) -> Int? {
    let up = t.uppercased()
    guard let m = up.range(of: #"(\d{1,2}):(\d{2})\s*([AP])"#, options: .regularExpression) else {
        return nil
    }
    let s = String(up[m])
    let digits = s.split(whereSeparator: { !$0.isNumber })
    guard digits.count >= 2, var h = Int(digits[0]), let min = Int(digits[1]) else { return nil }
    h %= 12
    if s.contains("P") { h += 12 }
    return h * 60 + min
}

func hhmm(_ m: Int) -> String {
    let h = (m / 60) % 12
    return "\(h == 0 ? 12 : h):\(String(format: "%02d", m % 60))"
}

func ampm(_ m: Int) -> String { m < 720 ? "am" : "pm" }

// MARK: - Local marks

/// One class ticked off by hand, so the portal does not have to be refreshed
/// just to see the effect of attending.
struct Mark: Codable, Hashable {
    var subject: String
    var attended: Bool
    /// The subject's portal total at the moment this was ticked. Once the
    /// portal's own total moves past it, this class has been counted for real
    /// and the mark is spent — which is how a mark survives a refresh that
    /// happened before the portal caught up.
    var total: Int

    init(subject: String, attended: Bool, total: Int) {
        self.subject = subject
        self.attended = attended
        self.total = total
    }

    /// Marks written before `total` existed decode as 0, which reads as
    /// "already absorbed" and drops them. That is the old behaviour, and the
    /// safe direction: under-counting beats double-counting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        attended = (try? c.decode(Bool.self, forKey: .attended)) ?? false
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
    }
}

/// The marks the portal has *not* yet counted.
///
/// A refresh used to clear every mark, on the theory that a portal read is
/// authoritative. It is — but it lags. Marking three classes and refreshing
/// the next morning threw them all away and the numbers fell back, leaving you
/// to re-mark from memory.
///
/// Each mark records the subject's portal total when it was made. If the
/// portal's total has since risen by n, then n of that subject's marked
/// classes have been counted; the oldest n are spent and the rest survive.
/// A mark key ("2026-09-19|03:00 PM|Physics") as something sortable.
///
/// Sorting the raw key is wrong: "03:00 PM" sorts before "09:00 AM" but
/// happens six hours later, so the afternoon's mark would be spent before the
/// morning's. Minutes since midnight, not string order.
private func markOrder(_ key: String) -> String {
    let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    let day = parts.first.map(String.init) ?? ""
    let mins = parts.count > 1 ? (toMinutes(String(parts[1])) ?? 0) : 0
    return day + String(format: "|%04d", mins)
}

func survivingMarks(_ marks: [String: Mark], after rows: [AttRow]) -> [String: Mark] {
    guard !marks.isEmpty, !rows.isEmpty else { return [:] }

    var grouped: [String: [(key: String, mark: Mark)]] = [:]
    for (key, mark) in marks {
        // A mark whose subject no longer resolves was never going to move a
        // number anyway, so it goes.
        guard let row = matchSubject(mark.subject, in: rows) else { continue }
        grouped[row.key, default: []].append((key, mark))
    }

    var out: [String: Mark] = [:]
    for (rowKey, list) in grouped {
        guard let row = rows.first(where: { $0.key == rowKey }) else { continue }
        let ordered = list.sorted { markOrder($0.key) < markOrder($1.key) }
        let base = ordered.map(\.mark.total).min() ?? row.total
        let absorbed = Swift.max(0, row.total - base)
        for (i, entry) in ordered.enumerated() where i >= absorbed {
            out[entry.key] = entry.mark
        }
    }
    return out
}

func markKey(_ k: Klass, on date: String) -> String {
    "\(date)|\(k.session.start)|\(k.subject)"
}

/// Folds hand-marked classes into the scraped totals. Each mark adds one held
/// class, and an attended one also adds to the numerator.
func applyMarks(_ rows: [AttRow], _ marks: [String: Mark]) -> [AttRow] {
    guard !marks.isEmpty else { return rows }
    var extra: [String: (Int, Int)] = [:]

    for mark in marks.values {
        guard let row = matchSubject(mark.subject, in: rows) else { continue }
        var e = extra[row.key] ?? (0, 0)
        e.0 += mark.attended ? 1 : 0
        e.1 += 1
        extra[row.key] = e
    }

    return rows.map { r in
        guard let e = extra[r.key] else { return r }
        return AttRow(key: r.key, attended: r.attended + e.0, total: r.total + e.1)
    }
}

// MARK: - A shaped day

struct Klass: Identifiable {
    let session: Session
    let s0: Int
    let s1: Int
    var live = false
    var past = false
    var next = false
    var att: AttRow?

    var id: String { session.id }
    var subject: String { session.subject }
    var room: String? { session.room }
    var online: Bool { session.online }
    var mode: String { session.mode }
    var link: String? { session.link }
}

/// Marks the class on now and the next one due, and ties each to its subject.
func shapeDay(sessions: [Session], rows: [AttRow], nowMin: Int) -> [Klass] {
    var list: [Klass] = sessions.compactMap { s in
        guard let a = toMinutes(s.start) else { return nil }
        // An end that is missing, unparseable, or not after the start used to
        // collapse the class to zero length, which reads as "already over"
        // from its own start minute: never live, past at once, no Join button.
        // ponytail: fixed 55-minute slot, which is what this portal issues.
        // Read a real duration off the payload if that ever stops holding.
        let b: Int
        if let e = toMinutes(s.end), e > a { b = e } else { b = a + 55 }
        return Klass(session: s, s0: a, s1: b, att: matchSubject(s.subject, in: rows))
    }
    .sorted { $0.s0 < $1.s0 }

    var nextIdx: Int?
    for i in list.indices {
        list[i].live = nowMin >= list[i].s0 && nowMin < list[i].s1
        list[i].past = nowMin >= list[i].s1
        if nextIdx == nil && !list[i].past && !list[i].live { nextIdx = i }
    }
    if let n = nextIdx { list[n].next = true }
    return list
}

/// Three states rather than two.
///
/// Coral used to mean "below the threshold", which in a term where every
/// subject is short paints the entire screen red. Reserving it for the one
/// subject actually gating you - and for anything now unreachable - gives the
/// rest somewhere quieter to sit.
enum Urgency {
    case fine, behind, critical
}

/// - Parameter blocker: `Summary.blocker`, the subject needing the most in a row.
func urgency(of row: AttRow, term: Term?, blocker: AttRow?) -> Urgency {
    if let t = term, t.remaining > 0, !t.reachable { return .critical }
    guard row.budget.state == .short else { return .fine }
    return row.key == blocker?.key ? .critical : .behind
}

// MARK: - The rest of the term

/// What the remaining timetable means for one subject.
///
/// The percentage on its own answers "where am I"; this answers "can I still
/// get there, and when". Only meaningful when the portal handed over the whole
/// term rather than the next few days - see `Snapshot.termEnd`.
struct Term {
    /// Classes still scheduled for this subject, today onwards.
    let remaining: Int
    /// Does attending every one of them reach the threshold?
    let reachable: Bool
    /// How many of `remaining` can be missed and still clear.
    let skippable: Int
    /// The date it crosses the threshold if every class from here is attended.
    /// nil when already clear, or when it cannot be reached at all.
    let clears: String?
    /// Last scheduled class for this subject. ISO yyyy-MM-dd.
    let last: String?
    /// Every remaining session date for this subject, ascending. Turns "needs
    /// 9 in a row" into nine actual dates you can put in a calendar.
    let dates: [String]
}

/// Ties the remaining timetable to the attendance rows, keyed by `AttRow.key`.
///
/// A term's worth of sessions repeats the same handful of subject names, so
/// each distinct name is resolved once rather than once per session - the
/// matcher is far too expensive to run several hundred times per render.
func termMap(rows: [AttRow], upcoming: [Session], threshold T: Int = THRESHOLD) -> [String: Term] {
    guard !rows.isEmpty, !upcoming.isEmpty else { return [:] }

    var byKey: [String: [String]] = [:]
    var resolved: [String: String?] = [:]

    for s in upcoming {
        guard let d = s.date else { continue }
        let key: String?
        if let seen = resolved[s.subject] {
            key = seen
        } else {
            let k = matchSubject(s.subject, in: rows)?.key
            resolved[s.subject] = k
            key = k
        }
        guard let k = key else { continue }
        byKey[k, default: []].append(d)
    }

    var out: [String: Term] = [:]
    for r in rows {
        let dates = (byKey[r.key] ?? []).sorted()
        let R = dates.count
        let a = r.attended
        let t = r.total

        // Attend all R:  (a+R)/(t+R) >= T/100
        let reachable = 100 * (a + R) >= T * (t + R)

        // Miss s of them: (a+R-s)/(t+R) >= T/100, largest such s. The
        // numerator can go negative, and max(0,) is what floors it there.
        let raw = (100 * a + (100 - T) * R - T * t) / 100
        let skippable = reachable ? max(0, min(R, raw)) : 0

        // Attending every class from here, the threshold is crossed at the
        // n-th one - and n is exactly the figure Budget already computes for
        // a short subject, so there is no second sum to keep in step.
        var clears: String?
        let b = r.budget
        if b.state == .short, reachable, b.value >= 1, b.value <= R {
            clears = dates[b.value - 1]
        }

        out[r.key] = Term(
            remaining: R, reachable: reachable,
            skippable: skippable, clears: clears, last: dates.last,
            dates: dates
        )
    }
    return out
}

/// "2026-10-14" -> "14 Oct", for the term lines.
func shortDate(_ iso: String) -> String {
    guard let d = Snapshot.isoDay.date(from: iso) else { return iso }
    return d.formatted(.dateTime.day().month(.abbreviated))
}

/// One line describing where a subject stands against the rest of the term.
/// The one thing worth saying about a term: when this subject is done
/// worrying about.
///
/// It used to carry "· 27 left" as well, on every row. The count of remaining
/// classes is not a fact anyone acts on - it is the raw material the clear
/// date is made of, printed next to the answer it was used to compute.
func termLine(_ b: Budget, _ tm: Term) -> String {
    if tm.remaining == 0 { return "no classes left" }
    if !tm.reachable { return "can't reach \(THRESHOLD)%" }
    if let c = tm.clears { return "clears \(shortDate(c))" }
    return "already above \(THRESHOLD)%"
}

struct Summary {
    let subjects: [AttRow]
    let overall: Budget
    let attended: Int
    let total: Int
    let failing: [AttRow]
    /// The subject that actually gates you: the one needing the most classes in
    /// a row. Lowest percentage is a different question — a subject at 50% off
    /// 1/2 needs far fewer classes than one at 67% off 8/12.
    let blocker: AttRow?

    init(_ rows: [AttRow]) {
        // Risk order. A subject with no classes held yet reads 0% but carries no
        // risk, so it sits at the bottom rather than heading the list.
        subjects = rows.sorted { x, y in
            let xe = x.budget.state == .empty
            let ye = y.budget.state == .empty
            if xe != ye { return ye }
            return x.budget.pct < y.budget.pct
        }
        attended = rows.reduce(0) { $0 + $1.attended }
        total = rows.reduce(0) { $0 + $1.total }
        overall = Budget(attended: attended, total: total)
        failing = subjects.filter { $0.budget.state == .short }
        blocker = failing.max {
            $0.budget.value != $1.budget.value
                ? $0.budget.value < $1.budget.value
                : $0.budget.pct > $1.budget.pct
        }
    }
}
