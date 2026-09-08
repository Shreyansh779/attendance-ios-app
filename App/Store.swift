import Foundation

/// What one successful read of the dashboard produced.
struct Snapshot: Codable {
    var savedAt: Date
    var rows: [AttRow]
    var sessions: [Session]
    var student: String?

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
