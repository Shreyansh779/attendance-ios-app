import Foundation

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
        photo = try? c.decodeIfPresent(String.self, forKey: .photo)
    }

    init(
        savedAt: Date, rows: [AttRow], sessions: [Session],
        student: String?, week: [String: [Session]] = [:],
        marks: [String: Mark] = [:], weekDiag: String? = nil,
        photo: String? = nil
    ) {
        self.savedAt = savedAt
        self.rows = rows
        self.sessions = sessions
        self.student = student
        self.week = week
        self.marks = marks
        self.weekDiag = weekDiag
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
