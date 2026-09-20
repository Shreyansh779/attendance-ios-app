import Foundation

/// A day, or a run of days, the university is shut.
///
/// `from` and `to` are ISO and inclusive; most are a single day, but Diwali is
/// five and Winter Break crosses a year.
struct Holiday: Codable, Hashable {
    let name: String
    let type: String
    let from: String
    let to: String
}

/// One class, as the portal's own register recorded it.
///
/// The dashboard only ever gives totals - 14 of 21 - which cannot answer
/// "which ones did I miss" or "how did this week go". The attendance search
/// page has the register itself, one row per session, and this is a row of it.
struct DaySession: Codable, Hashable {
    /// The app's own subject key, not the dropdown's wording, so this joins
    /// straight onto `AttRow`.
    let subject: String
    /// ISO yyyy-MM-dd.
    let date: String
    /// As printed: "17:00 - 17:55".
    let time: String
    let present: Bool
}

/// What the portal said on one day.
///
/// The app was entirely point-in-time: it knew you were at 72.6% but not that
/// you were at 70% a fortnight ago. Direction is the thing that tells you
/// whether a nine-class run is working, and the portal never reports it.
struct Stamp: Codable, Hashable {
    /// ISO yyyy-MM-dd. One stamp per day; a second read the same day replaces
    /// the first rather than adding a point.
    let day: String
    /// The portal's own figures, before hand-marks are folded in - otherwise
    /// the trend would move when you ticked a box rather than when you
    /// attended something.
    let rows: [AttRow]

    var attended: Int { rows.reduce(0) { $0 + $1.attended } }
    var total: Int { rows.reduce(0) { $0 + $1.total } }
    var pct: Double { total > 0 ? Double(attended) / Double(total) * 100 : 0 }
}

/// What one successful read of the dashboard produced.
struct Snapshot: Codable {
    var savedAt: Date
    var rows: [AttRow]
    var sessions: [Session]
    var student: String?
    /// Sessions by ISO date, accumulated across refreshes. The portal's agenda
    /// only ever shows six days from today, so merging is what eventually
    /// yields a full week.
    var week: [String: [Session]] = [:]
    /// Hand-marked classes, cleared whenever a real refresh lands.
    var marks: [String: Mark] = [:]
    /// What the weekly scrape saw, kept only so a failure is diagnosable.
    var weekDiag: String?
    /// Last day the timetable covers, set only when the whole term came
    /// through. nil means the cache holds a few days at most, and the term
    /// maths must stay quiet rather than call a subject hopeless on the
    /// strength of a six-day agenda.
    var termEnd: String?
    /// Oldest first. Capped, because this lives in UserDefaults.
    var history: [Stamp] = []
    /// Days with no teaching. The timetable feed still lists classes on some of
    /// them, and counting those as "remaining" makes recovery look easier than
    /// it is — which is the wrong direction to be wrong in.
    var holidays: [Holiday] = []
    /// Every session the register has, across every subject. Read last, on a
    /// separate page, and empty until that read has succeeded once.
    var daywise: [DaySession] = []
    /// The student's photo as a `data:image/...;base64,` URI, read off the
    /// dashboard header. Stored rather than re-fetched: the portal serves it
    /// inline, so there is no URL to load later.
    var photo: String?

    /// Decoded leniently: a cache written before week and marks existed should
    /// still load rather than being thrown away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = (try? c.decode(Date.self, forKey: .savedAt)) ?? Date()
        rows = (try? c.decode([AttRow].self, forKey: .rows)) ?? []
        sessions = (try? c.decode([Session].self, forKey: .sessions)) ?? []
        student = try? c.decodeIfPresent(String.self, forKey: .student)
        week = (try? c.decode([String: [Session]].self, forKey: .week)) ?? [:]
        marks = (try? c.decode([String: Mark].self, forKey: .marks)) ?? [:]
        weekDiag = try? c.decodeIfPresent(String.self, forKey: .weekDiag)
        termEnd = try? c.decodeIfPresent(String.self, forKey: .termEnd)
        history = (try? c.decode([Stamp].self, forKey: .history)) ?? []
        holidays = (try? c.decode([Holiday].self, forKey: .holidays)) ?? []
        daywise = (try? c.decode([DaySession].self, forKey: .daywise)) ?? []
        photo = try? c.decodeIfPresent(String.self, forKey: .photo)
    }

    init(
        savedAt: Date, rows: [AttRow], sessions: [Session],
        student: String?, week: [String: [Session]] = [:],
        marks: [String: Mark] = [:], weekDiag: String? = nil,
        termEnd: String? = nil, history: [Stamp] = [],
        holidays: [Holiday] = [], daywise: [DaySession] = [],
        photo: String? = nil
    ) {
        self.savedAt = savedAt
        self.rows = rows
        self.sessions = sessions
        self.student = student
        self.week = week
        self.marks = marks
        self.weekDiag = weekDiag
        self.termEnd = termEnd
        self.history = history
        self.holidays = holidays
        self.daywise = daywise
        self.photo = photo
    }

    static var isoDay: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        // A fixed format needs a fixed locale. Otherwise the current locale's
        // numbering system applies, so a region defaulting to Arabic-Indic or
        // Devanagari digits writes the date in those digits and never matches
        // the ASCII keys the scrapers produce - at which point the whole
        // weekly timetable silently disappears.
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// Today's classes: the weekly scrape if we have it, else the dashboard card.
    func sessions(for date: Date) -> [Session] {
        let key = Snapshot.isoDay.string(from: date)
        if let day = week[key], !day.isEmpty { return day }
        return Snapshot.isoDay.string(from: savedAt) == key ? sessions : []
    }

    /// The holiday covering this day, if any.
    func holiday(on day: String) -> Holiday? {
        holidays.first { $0.from <= day && day <= $0.to }
    }

    /// Every class still to come, today onwards, ascending — minus the ones
    /// scheduled on days the university is shut, which will not be held and
    /// must not be counted as recoverable.
    func upcoming(from date: Date) -> [Session] {
        let today = Snapshot.isoDay.string(from: date)
        return week
            .filter { $0.key >= today && holiday(on: $0.key) == nil }
            .sorted { $0.key < $1.key }
            .flatMap { $0.value }
    }

    /// Today's reading folded in, replacing any earlier one from the same day.
    static func extend(_ history: [Stamp], with rows: [AttRow], on date: Date) -> [Stamp] {
        guard !rows.isEmpty else { return history }
        let key = Snapshot.isoDay.string(from: date)
        var out = history.filter { $0.day != key }
        out.append(Stamp(day: key, rows: rows))
        out.sort { $0.day < $1.day }
        // A term is ~120 teaching days; past that the oldest points stop
        // earning their bytes.
        if out.count > 120 { out.removeFirst(out.count - 120) }
        return out
    }

    /// Monday to Sunday around `now`, as ISO days.
    ///
    /// Not `Calendar.dateInterval(of: .weekOfYear)`: that honours the locale's
    /// first weekday, which here is Sunday, and a week that starts on Sunday
    /// puts the weekend at both ends of the timetable.
    static func week(of now: Date) -> (from: String, to: String) {
        let cal = Calendar.current
        let back = (cal.component(.weekday, from: now) + 5) % 7
        let mon = cal.date(byAdding: .day, value: -back, to: now) ?? now
        let sun = cal.date(byAdding: .day, value: 6, to: mon) ?? now
        return (isoDay.string(from: mon), isoDay.string(from: sun))
    }

    var ageHours: Double { Date().timeIntervalSince(savedAt) / 3600 }

    var ageText: String {
        let h = ageHours
        if h < 1 { return "Updated just now" }
        if h < 24 { return "Updated \(Int(h.rounded()))h ago" }
        return "Updated \(Int((h / 24).rounded()))d ago"
    }
}

/// Plain UserDefaults. No App Group is needed because there is no widget, which
/// is the whole reason free-tier signing is workable here.
enum Store {
    private static let key = "today.snapshot.v1"

    static func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ s: Snapshot) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
