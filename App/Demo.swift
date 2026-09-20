#if DEBUG
    import Foundation

    /// A term that never happened, so the app can be looked at without a login.
    ///
    /// Every screen in this app is empty until somebody has solved a captcha on
    /// the portal, which means no automated pass over it — no simulator, no CI
    /// screenshot, no preview — ever sees anything but the empty state. That
    /// makes visual regressions something only a human with the real app can
    /// find, and they find them one screenshot at a time.
    ///
    /// This is the fixture behind `-demo`. It is deliberately awkward: three
    /// urgency states, a class happening right now, an online one with a join
    /// link, one already ticked by hand, a holiday two days out, a subject that
    /// cannot recover, and a register with absences in it. A fixture where
    /// everything is fine proves nothing.
    ///
    /// DEBUG only, so none of it can reach the build that gets sideloaded.
    enum Demo {
        static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

        /// Which screen to open on: today, timetable, attendance, subject.
        static var tab: String { value("-tab") ?? "today" }

        /// Whether to open the settings sheet on launch.
        static var showsSettings: Bool { value("-sheet") == "settings" }

        private static func value(_ flag: String) -> String? {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
            return a[i + 1]
        }

        // MARK: - The term

        private static let cal = Calendar.current

        private static let clock: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "hh:mm a"
            return f
        }()

        private static func day(_ offset: Int, from now: Date) -> String {
            Snapshot.isoDay.string(from: cal.date(byAdding: .day, value: offset, to: now) ?? now)
        }

        private static func at(_ minutes: Int, from now: Date) -> String {
            clock.string(from: now.addingTimeInterval(TimeInterval(minutes * 60)))
        }

        /// Six subjects: one comfortably clear, two behind, one that gates the
        /// whole term, one that can no longer reach the line, one not started.
        private static let rows: [AttRow] = [
            AttRow(key: "Web Analytics", attended: 19, total: 21),
            AttRow(key: "Object Oriented Analysis and Design", attended: 14, total: 20),
            AttRow(key: "Formal Languages and Automata Theory", attended: 12, total: 18),
            AttRow(key: "Research Methodology in CS", attended: 14, total: 21),
            AttRow(key: "Probability, Entropy, and MC Simulation", attended: 9, total: 17),
            AttRow(key: "Cryptography and Network Security", attended: 0, total: 0),
        ]

        static func snapshot(now: Date = Date()) -> Snapshot {
            // One finished, one happening right now, one online in an hour, one
            // later - which is every state the Today screen can be in.
            let today = [
                Session(
                    subject: "Object Oriented Analysis and Design",
                    start: at(-190, from: now), end: at(-135, from: now),
                    room: "11214", online: false, mode: "class", date: day(0, from: now)
                ),
                Session(
                    subject: "Formal Languages and Automata Theory",
                    start: at(-20, from: now), end: at(35, from: now),
                    room: "11213", online: false, mode: "class", date: day(0, from: now)
                ),
                Session(
                    subject: "Web Analytics",
                    start: at(75, from: now), end: at(130, from: now),
                    room: nil, online: true, mode: "virtual", date: day(0, from: now),
                    link: "https://teams.microsoft.com/l/meetup-join/demo"
                ),
                Session(
                    subject: "Research Methodology in CS",
                    start: at(200, from: now), end: at(255, from: now),
                    room: "11207", online: false, mode: "class", date: day(0, from: now)
                ),
            ]

            // A fortnight either side, so paging back and forward both land on
            // something and the term maths has a tail to work with.
            var week: [String: [Session]] = [day(0, from: now): today]
            for d in -14...45 where d != 0 {
                let iso = day(d, from: now)
                let weekday = cal.component(
                    .weekday, from: cal.date(byAdding: .day, value: d, to: now) ?? now
                )
                if weekday == 1 { continue }
                week[iso] = [
                    Session(
                        subject: rows[abs(d) % 5].key,
                        start: "09:00 AM", end: "09:55 AM",
                        room: "1121\(abs(d) % 5)", online: false, mode: "class", date: iso
                    ),
                    Session(
                        subject: rows[(abs(d) + 2) % 5].key,
                        start: "11:00 AM", end: "11:55 AM",
                        room: nil, online: (d % 3 == 0), mode: d % 3 == 0 ? "virtual" : "class",
                        date: iso,
                        link: d % 3 == 0 ? "https://teams.microsoft.com/l/meetup-join/demo" : nil
                    ),
                    Session(
                        subject: rows[(abs(d) + 4) % 5].key,
                        start: "02:00 PM", end: "02:55 PM",
                        room: "11213", online: false, mode: "class", date: iso
                    ),
                ]
            }

            // Two readings a week apart, which is the minimum the trend line
            // will draw anything from.
            let history = [
                Stamp(
                    day: day(-9, from: now),
                    rows: rows.map { AttRow(key: $0.key, attended: max(0, $0.attended - 3), total: max(0, $0.total - 4)) }
                ),
                Stamp(
                    day: day(-4, from: now),
                    rows: rows.map { AttRow(key: $0.key, attended: max(0, $0.attended - 1), total: max(0, $0.total - 2)) }
                ),
                Stamp(day: day(0, from: now), rows: rows),
            ]

            return Snapshot(
                savedAt: now.addingTimeInterval(-40 * 60),
                rows: rows,
                sessions: today,
                student: "Shreyansh Singhal",
                week: week,
                marks: [
                    // Already ticked, so the answered state is on screen too.
                    "\(day(0, from: now))|\(at(-190, from: now))|Object Oriented Analysis and Design":
                        Mark(subject: "Object Oriented Analysis and Design", attended: true, total: 20)
                ],
                weekDiag: nil,
                termEnd: day(45, from: now),
                history: history,
                holidays: [
                    Holiday(
                        name: "Gandhi Jayanti", type: "National Holiday",
                        from: day(2, from: now), to: day(2, from: now)
                    )
                ],
                daywise: register(now: now),
                attDiag: nil,
                photo: nil
            )
        }

        /// Ten days of register rows, with a run of absences in the subject
        /// that is in trouble - otherwise every dot is the same colour and the
        /// screen proves nothing.
        private static func register(now: Date) -> [DaySession] {
            var out: [DaySession] = []
            for d in stride(from: -11, through: 0, by: 1) {
                let weekday = cal.component(
                    .weekday, from: cal.date(byAdding: .day, value: d, to: now) ?? now
                )
                if weekday == 1 || weekday == 7 { continue }
                let iso = day(d, from: now)
                out.append(
                    DaySession(
                        subject: "Research Methodology in CS", date: iso,
                        time: "15:00 - 15:55", present: d % 3 != 0
                    )
                )
                out.append(
                    DaySession(
                        subject: "Web Analytics", date: iso,
                        time: "11:00 - 11:55", present: true
                    )
                )
                out.append(
                    DaySession(
                        subject: "Formal Languages and Automata Theory", date: iso,
                        time: "09:00 - 09:55", present: d % 4 != 0
                    )
                )
            }
            return out
        }
    }
#endif
