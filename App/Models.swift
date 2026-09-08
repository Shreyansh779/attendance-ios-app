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

    var id: String { start + subject }

    enum CodingKeys: String, CodingKey { case subject, start, end, room, online, mode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? "Class"
        start = (try? c.decode(String.self, forKey: .start)) ?? ""
        end = (try? c.decode(String.self, forKey: .end)) ?? ""
        room = try? c.decodeIfPresent(String.self, forKey: .room)
        online = (try? c.decode(Bool.self, forKey: .online)) ?? false
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "class"
    }

    init(subject: String, start: String, end: String, room: String?, online: Bool, mode: String) {
        self.subject = subject
        self.start = start
        self.end = end
        self.room = room
        self.online = online
        self.mode = mode
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
}

/// Marks the class on now and the next one due, and ties each to its subject.
func shapeDay(sessions: [Session], rows: [AttRow], nowMin: Int) -> [Klass] {
    var list: [Klass] = sessions.compactMap { s in
        guard let a = toMinutes(s.start), let b = toMinutes(s.end) else { return nil }
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

struct Summary {
    let subjects: [AttRow]
    let overall: Budget
    let attended: Int
    let total: Int
    let failing: [AttRow]

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
    }
}
