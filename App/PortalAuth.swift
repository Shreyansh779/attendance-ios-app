import Foundation
import Security

/// Direct login against the myUPES mobile OAuth2 endpoint - the same one the
/// SLCM app uses - as an alternative to driving `Portal`'s WKWebView through
/// the captcha-gated web login.
///
/// Confirmed working 2026-10-13 against a live account: the mobile client
/// (`x-requestfrom: mobile`) skips the captcha the web login enforces, taking
/// a literal `"-"` in its place. Found by decompiling the SLCM app's Hermes
/// bundle; this is not a documented API and UPES could tighten it without
/// notice, which is why `Portal`'s WKWebView path stays as the fallback -
/// deleting the recovery path for an endpoint we don't control would be
/// fragility, not simplicity.
enum PortalAuth {

    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String
        var clientId: Int
        var clientSecret: String
        /// Set from the login/refresh response's ISO "now" plus the server's
        /// `ExpiresIn`. The field's unit doesn't match its name - a login
        /// observed with `ExpiresIn: 1` carried a JWT good for ~8.5 hours -
        /// so this is read once at login/refresh time rather than trusted
        /// literally, and treated as a floor: refresh early, not exactly on it.
        var expiresAt: Date

        var isExpiringSoon: Bool { Date().addingTimeInterval(5 * 60) >= expiresAt }
    }

    enum AuthError: Error {
        case badCredentials
        case server(status: Int)
        case malformedResponse
    }

    private static let baseURL = URL(string: "https://myupes-beta.upes.ac.in/")!

    /// `UserId`/`Password`/`Captcha` login. Captcha is a literal "-" on the
    /// mobile client; the web login requires a real reCAPTCHA token instead,
    /// which is the whole reason `Portal` exists.
    static func login(email: String, password: String) async throws -> Credentials {
        var request = URLRequest(url: baseURL.appendingPathComponent("sso/api/account/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("oneportal", forHTTPHeaderField: "x-applicationname")
        request.setValue("mobile", forHTTPHeaderField: "x-requestfrom")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "UserId": email.trimmingCharacters(in: .whitespaces),
            "Password": password,
            "Captcha": "-",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parse(data: data, response: response)
    }

    /// `sso/user/oauth2/refresh-token`, using the client id/secret the login
    /// response handed back alongside the refresh token itself.
    static func refresh(_ credentials: Credentials) async throws -> Credentials {
        var request = URLRequest(url: baseURL.appendingPathComponent("sso/user/oauth2/refresh-token"))
        request.httpMethod = "POST"
        request.setValue("connectportal", forHTTPHeaderField: "x-applicationname")
        request.setValue("mobile", forHTTPHeaderField: "x-requestfrom")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "ClientId": String(credentials.clientId),
            "ClientSecret": credentials.clientSecret,
            "RefreshToken": credentials.refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parse(data: data, response: response)
    }

    /// Both login and refresh answer with the same `Item.Identity` /
    /// `Item.ClientInfo` shape, confirmed against a live response.
    private static func parse(data: Data, response: URLResponse) throws -> Credentials {
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformedResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 400 { throw AuthError.badCredentials }
            throw AuthError.server(status: http.statusCode)
        }
        struct Envelope: Decodable {
            struct Item: Decodable {
                struct Identity: Decodable {
                    var AccessToken: String
                    var RefreshToken: String
                    var ExpiresIn: Double
                }
                struct ClientInfo: Decodable {
                    var Id: Int
                    var Secret: String
                }
                var Identity: Identity
                var ClientInfo: ClientInfo
            }
            var Item: Item
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AuthError.malformedResponse
        }
        let identity = envelope.Item.Identity
        return Credentials(
            accessToken: identity.AccessToken,
            refreshToken: identity.RefreshToken,
            clientId: envelope.Item.ClientInfo.Id,
            clientSecret: envelope.Item.ClientInfo.Secret,
            expiresAt: Date().addingTimeInterval(identity.ExpiresIn * 3600)
        )
    }
}

/// Keychain storage for `PortalAuth.Credentials`. A SecItem generic password,
/// not UserDefaults like `Store` - these are live bearer tokens, not cached
/// portal rows.
enum PortalAuthStore {
    private static let service = "today.portal-auth"
    private static let account = "slcm"

    static func load() -> PortalAuth.Credentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PortalAuth.Credentials.self, from: data)
    }

    static func save(_ credentials: PortalAuth.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain storage for the raw email/password, kept separately from the
/// bearer tokens so a dead token (revoked, or a stale one left over from
/// testing) can be silently replaced with a fresh login instead of
/// immediately asking the person to type their password again. Same
/// SecItem-generic-password approach as `PortalAuthStore`, not UserDefaults -
/// this is a password, not cached portal rows.
enum PortalCredentialStore {
    private static let service = "today.portal-credentials"
    private static let account = "slcm-login"

    struct Saved: Codable {
        var email: String
        var password: String
    }

    static func load() -> Saved? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The `apigateway/*` calls, confirmed live 2026-10-13 against a real account
/// with a token from `PortalAuth.login`. All three (student id lookup, the
/// term/course dropdown, the detailed register) returned real data with the
/// same mobile header pair and no `x-appsecret`/`x-studentUniqueId` - this is
/// what would let `Portal.fetchDaywise`'s WKWebView-driven
/// `registerStart`/`registerRead` retire in favour of a plain network call,
/// if and when that's wired in.
enum PortalGateway {

    enum GatewayError: Error, CustomStringConvertible {
        case unauthorized
        case server(status: Int)
        case malformedResponse
        /// 200, but the JSON didn't match the expected shape - carries a
        /// clipped raw body so a wrong field-name guess is diagnosable from
        /// the device instead of showing a label with no evidence behind it.
        case decodeFailed(String)

        var description: String {
            switch self {
            case .unauthorized: return "unauthorized"
            case .server(let status): return "server \(status)"
            case .malformedResponse: return "malformed response"
            case .decodeFailed(let body): return "decode failed: \(body)"
            }
        }
    }

    private static let base = URL(string: "https://myupes-beta.upes.ac.in/apigateway/")!

    private static func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer " + token,
            "x-applicationname": "connectportal",
            "x-requestfrom": "mobile",
            "Content-Type": "application/json",
        ]
    }

    private static func send(_ path: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        for (k, v) in headers(token) { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GatewayError.malformedResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw GatewayError.unauthorized }
            throw GatewayError.server(status: http.statusCode)
        }
        return data
    }

    struct StudentIdentity {
        /// The GUID `studentattendancesummary` and `attendancedropdown` want
        /// as `StudentUniqueID` - distinct from `GlobalId`, which other
        /// endpoints (e.g. `usercontext`'s `RoleId`-keyed calls) use instead.
        var studentId: String
        /// Confirmed live 2026-10-13 to not actually be on this response;
        /// defaulted to 0 rather than failing the whole identity fetch.
        /// `detailedRegister`'s real requirement for it is unconfirmed.
        var courseFamilyId: Int
        var name: String?
        /// The id the WebView scraper's profile-picture path
        /// (`590011979_P.jpg`) is built from - a quoted string in the real
        /// response, not a number. Kept around as a cross-check if
        /// `profilePicture`'s field names ever need re-deriving by hand.
        var globalId: String?
        var email: String?
        var phone: String?
        var campus: String?
        var program: String?
        /// What `profilePhoto` needs. ponytail: `ContainerName`'s exact key
        /// wasn't pinned down live the way the rest of this struct was - if
        /// it's named differently the photo fetch just throws and the merge
        /// in `PortalDirect` keeps whatever photo was cached, same as every
        /// other best-effort field here.
        var profilePicture: ProfilePicture?
        /// Set only when `ProfilePictureInfo` exists but didn't fully decode
        /// - the real key names, read straight off the JSON rather than
        /// guessed, so a wrong guess is fixable from one device run instead
        /// of another round of blind curl commands.
        var profilePictureRawKeys: String?
    }

    struct ProfilePicture {
        var containerName: String
        var filePath: String
        var actualFileName: String
    }

    /// `GET connect-portal/api/studentloginbasicinfo`, Bearer-only.
    static func studentIdentity(token: String) async throws -> StudentIdentity {
        let data = try await send("connect-portal/api/studentloginbasicinfo", token: token)
        struct Picture: Decodable {
            var ContainerName: String?
            var FilePath: String?
            var ActualFileName: String?
        }
        struct Envelope: Decodable {
            struct Item: Decodable {
                var StudentId: String
                // Confirmed live 2026-10-13: not present as a plain
                // CourseFamilyId on this response at all (it carries
                // TermCodeID/TermCode/TermName instead) - defaulted rather
                // than required, since `detailedRegister`'s only use of it is
                // uncertain until a live register call confirms what it
                // actually needs.
                var CourseFamilyId: Int?
                var FirstName: String?
                var MiddleName: String?
                var LastName: String?
                // A quoted string in the real response ("590011979"), not a
                // number - decoding it as Int silently failed the whole Item,
                // which is what actually broke this call the first time.
                var GlobalId: String?
                var EmailId: String?
                var MobileNo: String?
                var CenterName: String?
                var CourseFamilyName: String?
                var ProfilePictureInfo: Picture?
            }
            var Items: [Item]
        }
        guard let item = try? JSONDecoder().decode(Envelope.self, from: data).Items.first else {
            let body = String(data: data.prefix(3000), encoding: .utf8) ?? "<binary>"
            throw GatewayError.decodeFailed(body)
        }
        let name = [item.FirstName, item.MiddleName, item.LastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let picture: ProfilePicture? = {
            guard let p = item.ProfilePictureInfo, let container = p.ContainerName, let path = p.FilePath
            else { return nil }
            // Confirmed live: this response carries ContainerName/FilePath
            // only, no ActualFileName key at all - the filename is just the
            // last segment of FilePath itself ("/students/profile-pictures/
            // 590011979_P.jpg" -> "590011979_P.jpg"), which is also what the
            // WebView-confirmed working curl call used.
            let derivedName = p.ActualFileName ?? (path as NSString).lastPathComponent
            return ProfilePicture(containerName: container, filePath: path, actualFileName: derivedName)
        }()
        // `ProfilePictureInfo` exists but something in `Picture` came back
        // nil - read its actual keys straight from the JSON so the real
        // field names are known rather than guessed a second time.
        var rawKeys: String?
        if picture == nil,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = obj["Items"] as? [[String: Any]],
            let pic = items.first?["ProfilePictureInfo"] as? [String: Any]
        {
            rawKeys = pic.keys.sorted().joined(separator: ",")
        }
        return StudentIdentity(
            studentId: item.StudentId, courseFamilyId: item.CourseFamilyId ?? 0,
            name: name.isEmpty ? nil : name, globalId: item.GlobalId,
            email: item.EmailId, phone: item.MobileNo,
            campus: item.CenterName, program: item.CourseFamilyName,
            profilePicture: picture, profilePictureRawKeys: rawKeys
        )
    }

    struct TermInfo {
        var termCodeId: Int
        var termStartDate: String  // ISO, as the server sent it
        var termEndDate: String
        var modules: [(id: Int, name: String)]
    }

    /// `POST student-attendance/attendancedropdown`. Picks the term flagged
    /// `IsCurrentTerm`, falling back to the last one listed - same rule as
    /// `Scrapers.registerStart`.
    static func currentTerm(token: String, studentId: String) async throws -> TermInfo {
        let data = try await send(
            "student-attendance/attendancedropdown", token: token,
            body: ["StudentUniqueID": studentId, "IsAttendance": true]
        )
        struct Module: Decodable { var ModuleId: Int; var ModuleName: String }
        struct Term: Decodable {
            var IsCurrentTerm: Bool
            var TermCodeId: Int
            var TermStartDate: String
            var TermEndDate: String
            var ModuleDropdownDetailsList: [Module]
        }
        struct Family: Decodable { var TermDropdownDetailsList: [Term] }
        guard let terms = try? JSONDecoder().decode([Family].self, from: data).first?.TermDropdownDetailsList,
            let term = terms.first(where: { $0.IsCurrentTerm }) ?? terms.last
        else {
            let body = String(data: data.prefix(3000), encoding: .utf8) ?? "<binary>"
            throw GatewayError.decodeFailed(body)
        }
        return TermInfo(
            termCodeId: term.TermCodeId,
            termStartDate: term.TermStartDate,
            termEndDate: term.TermEndDate,
            modules: term.ModuleDropdownDetailsList.map { ($0.ModuleId, $0.ModuleName) }
        )
    }

    struct SessionRow {
        var courseName: String
        var date: String  // yyyy-MM-dd
        var time: String
        var present: Bool
    }

    /// `POST student-attendance/studentattendancesummary`, the full body
    /// (every course in the term, not just `dashboardattendance`) - same
    /// shape `Scrapers.registerRead` builds, confirmed live with these headers.
    static func detailedRegister(
        token: String, studentId: String, courseFamilyId: Int, term: TermInfo
    ) async throws -> [SessionRow] {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        let today = iso.string(from: Date())
        let startDate = String(term.termStartDate.prefix(10))
        let endDate = String(term.termEndDate.prefix(10))

        let body: [String: Any] = [
            "StudentUniqueID": studentId,
            "CourseFamilyId": courseFamilyId,
            "TermCodeId": term.termCodeId,
            "CourseList": term.modules.map { ["ID": $0.id, "Name": $0.name] },
            "StartDate": startDate,
            "EndDate": today,
            "TermStartDate": startDate,
            "TermEndDate": endDate,
        ]
        let data = try await send("student-attendance/studentattendancesummary", token: token, body: body)

        struct Detail: Decodable {
            var SessionDate: String
            var SessionTime: String
            var AttendanceStatus: String
        }
        struct Course: Decodable { var CourseName: String; var AttendanceDetails: [Detail] }
        struct Envelope: Decodable { var AttendanceInfo: [Course] }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            let body = String(data: data.prefix(3000), encoding: .utf8) ?? "<binary>"
            throw GatewayError.decodeFailed(body)
        }
        return envelope.AttendanceInfo.flatMap { course in
            course.AttendanceDetails.compactMap { detail -> SessionRow? in
                let day = String(detail.SessionDate.prefix(10))
                guard day.count == 10 else { return nil }
                return SessionRow(
                    courseName: course.CourseName,
                    date: day,
                    time: detail.SessionTime,
                    present: detail.AttendanceStatus.uppercased().hasPrefix("PRESENT")
                )
            }
        }
    }

    // MARK: - Timetable

    /// `POST api/timetable`, `ActivityCode: "studentdashboard"`, confirmed live
    /// only with a multi-day `SlotStartDate`/`SlotEndDate` range - a single-day
    /// range answered empty even on a day with real classes, which looks like a
    /// server-side off-by-one on the range boundary rather than a client bug.
    ///
    /// The response is a flat array, one entry per slot (not grouped by day),
    /// confirmed live 2026-10-13: `SlotDate` is `"2026-Oct-12"`, times are
    /// `"10:00 AM"` already in the app's own display format, the room/Teams
    /// link lives under `FloorPlanDetails`, and the subject name is
    /// `ModuleList[0].ModuleName` - there can be more than one module per slot
    /// in principle, but every live entry so far carries exactly one.
    /// Alongside the sessions, every subject's teacher names - pulled from
    /// `TeacherList`, which the response carries on every slot but which
    /// `Session` had no field for and `PortalDirect` was dropping entirely.
    /// Not consumed by anything yet (`Portal.fetchCourses`, the WebView-side
    /// Moodle course filter, is the only current reader of this shape), but
    /// it's free to carry along now rather than re-fetched later.
    static func timetable(
        token: String, studentCode: String, from: Date, to: Date
    ) async throws -> (sessions: [Session], faculty: [String: [String]]) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "dd-MMM-yyyy"
        let body: [String: Any] = [
            "ActivityCode": "studentdashboard",
            "TimeTableContextDetails": [
                "StudentCode": studentCode,
                "SlotStartDate": fmt.string(from: from),
                "SlotEndDate": fmt.string(from: to),
            ],
        ]
        let data = try await send("api/timetable", token: token, body: body)

        struct Module: Decodable { var ModuleName: String }
        struct Venue: Decodable {
            var VenueName: String?
            var VenueCategory: String?
            var MeetingLink: String?
        }
        struct Teacher: Decodable { var Name: String }
        struct Cohort: Decodable { var CohortGroupName: String?; var Code: String? }
        struct Row: Decodable {
            var FloorPlanDetails: Venue?
            var SlotDate: String
            var SlotStartTime: String
            var SlotEndTime: String
            var ModuleList: [Module]
            var TeacherList: [Teacher]?
            var CohortList: [Cohort]?
            var IsCancelledSlot: Bool?
        }

        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return ([], [:]) }

        let slotDate = DateFormatter()
        slotDate.locale = Locale(identifier: "en_US_POSIX")
        slotDate.dateFormat = "yyyy-MMM-dd"
        let isoDay = DateFormatter()
        isoDay.locale = Locale(identifier: "en_US_POSIX")
        isoDay.dateFormat = "yyyy-MM-dd"
        let batchCode = try? NSRegularExpression(pattern: #"B\d+"#)

        var faculty: [String: [String]] = [:]
        let sessions: [Session] = rows.compactMap { r -> Session? in
            guard r.IsCancelledSlot != true, let subject = r.ModuleList.first?.ModuleName else { return nil }
            let link = r.FloorPlanDetails?.MeetingLink.flatMap { $0.isEmpty ? nil : $0 }
            let date = slotDate.date(from: r.SlotDate).map { isoDay.string(from: $0) } ?? r.SlotDate

            let teachers = (r.TeacherList ?? []).map(\.Name)
            if !teachers.isEmpty {
                faculty[subject] = Array(Set((faculty[subject] ?? []) + teachers)).sorted()
            }

            // Confirmed live: `CohortGroupName` is the same full descriptive
            // string as `Code` ("BT-CSE-SPZ-CSF-V-B9"), not a short code on
            // its own - a regex pulling just the batch letter+number is the
            // only part of either field that's actually stable.
            let batches: [String] = (r.CohortList ?? []).compactMap { c -> String? in
                guard let regex = batchCode else { return nil }
                for candidate in [c.CohortGroupName, c.Code] {
                    guard let s = candidate,
                        let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                        let range = Range(m.range, in: s)
                    else { continue }
                    return String(s[range])
                }
                return nil
            }

            return Session(
                subject: subject, start: r.SlotStartTime, end: r.SlotEndTime,
                room: r.FloorPlanDetails?.VenueName, online: link != nil,
                mode: link != nil ? "online" : "class",
                date: date, link: link,
                batch: batches.isEmpty ? nil : Array(Set(batches)).sorted()
            )
        }
        return (sessions, faculty)
    }

    // MARK: - Exam schedule

    /// `POST integratons/api/data/exam-pro` (the misspelling is the server's).
    /// Confirmed live returning an empty list when no exams are published yet;
    /// the shape of a populated response hasn't been seen, so this only
    /// confirms the endpoint answers 200 for now.
    static func examSchedule(token: String, studentId: String) async throws -> Data {
        try await send(
            "integratons/api/data/exam-pro", token: token,
            body: ["ActivityCode": "examtimetable", "StudentUniqueId": studentId]
        )
    }

    // MARK: - Profile photo

    /// `POST docstorage/api/storage/downloadfile`. Needs the real
    /// `BlobRelativePath`/`ActualFileName` from `studentloginbasicinfo`'s
    /// `ProfilePictureInfo` - a placeholder path 500s, an empty one 500s, only
    /// the actual file resolves.
    static func profilePhoto(
        token: String, containerName: String, blobRelativePath: String, actualFileName: String
    ) async throws -> Data {
        try await send(
            "docstorage/api/storage/downloadfile", token: token,
            body: [
                "ContainerName": containerName,
                "BlobRelativePath": blobRelativePath,
                "ActualFileName": actualFileName,
            ]
        )
    }
}

/// Moodle's own Mobile app protocol - `admin/tool/mobile/launch.php`, a
/// `wstoken`, `webservice/rest/server.php` - confirmed from the real UPES
/// LMS app's decompiled source (`com.upes.studentlms`): it's an unmodified
/// build of the official Moodle Mobile app (moodlehq/moodleapp), not a
/// custom integration. Found after `PortalLMS`'s userkey handoff turned out
/// to reliably fail for Bearer-token auth while working for the WebView's
/// cookie-session auth - this is the better-founded alternative: Moodle's
/// own long-lived API credential, not a one-shot SSO redirect that has to be
/// re-spent every refresh.
///
/// The trade: this still needs an authenticated Moodle *cookie* session to
/// mint the token in the first place - `PortalGateway`'s Bearer tokens don't
/// help here, same root cause as the userkey flow's failure. But unlike that
/// flow, the mint only has to happen once (or whenever the stored token goes
/// stale): `PortalDirect` borrows `Portal`'s WebView cookies for that one
/// exchange, then every future refresh calls `webservice/rest/server.php`
/// directly - no cookies, no sesskey, no WebView, no per-refresh dance.
enum PortalMoodle {
    enum MoodleError: Error, CustomStringConvertible {
        case noAuthenticatedSession
        case noRedirect(String)
        case server(status: Int)
        case decodeFailed(String)
        case apiError(String)

        var description: String {
            switch self {
            case .noAuthenticatedSession: return "no authenticated Moodle session in the WebView"
            case .noRedirect(let body): return "no moodlemobile redirect: \(body)"
            case .server(let status): return "server \(status)"
            case .decodeFailed(let body): return "decode failed: \(body)"
            case .apiError(let msg): return "api error: \(msg)"
            }
        }
    }

    private static let lmsBase = URL(string: "https://lms.upes.ac.in/")!

    /// Reads the `Location` header of the launch.php redirect without
    /// following it - `moodlemobile://...` isn't an http(s) URL, so
    /// URLSession can't fetch it anyway, but it can tell us where it was
    /// headed.
    private final class RedirectCapture: NSObject, URLSessionTaskDelegate {
        var location: String?
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            location = response.value(forHTTPHeaderField: "Location")
            completionHandler(nil)
        }
    }

    /// The exact handshake `confirmAndOpenBrowserForSSOLogin` /
    /// `openBrowserForSSOLogin` in the real LMS app's source perform:
    /// `launch.php?service=moodle_mobile_app&passport=<random>&urlscheme=moodlemobile`,
    /// which - with a live Moodle session - redirects to
    /// `moodlemobile://user@host?token=TOKEN&privatetoken=PRIVATETOKEN`.
    /// `cookies` has to carry a real Moodle session; `Portal.allCookies()`
    /// is the only source of one in this app.
    static func exchangeForWSToken(cookies: [HTTPCookie]) async throws -> (token: String, privateToken: String) {
        guard cookies.contains(where: { $0.domain.contains("lms.upes.ac.in") }) else {
            throw MoodleError.noAuthenticatedSession
        }

        let passport = Int.random(in: 100_000...999_999)
        var components = URLComponents(
            url: lmsBase.appendingPathComponent("admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: String(passport)),
            URLQueryItem(name: "urlscheme", value: "moodlemobile"),
        ]

        var request = URLRequest(url: components.url!)
        let cookieHeader = cookies.filter { $0.domain.contains("lms.upes.ac.in") }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let capture = RedirectCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        _ = try? await session.data(for: request)

        guard let location = capture.location, location.hasPrefix("moodlemobile://") else {
            throw MoodleError.noRedirect(capture.location ?? "<no redirect at all>")
        }
        // Confirmed live 2026-10-15 against the real redirect, and against
        // `CoreLoginHelperProvider.validateBrowserSSOLogin` in the real LMS
        // app's decompiled source: this is NOT "scheme://host?key=value"
        // query syntax at all (a first guess that only produced
        // "no moodlemobile redirect" errors) - it's a single value straight
        // after "token=", itself base64 for `signature:::token:::privatetoken`.
        // `params[0]` (signature) is `md5(siteUrl + passport)`, used by the
        // real app to guard against a forged redirect; skipped here since
        // this is our own request to a host we already trust, not an
        // externally-triggered deep link.
        guard let range = location.range(of: "token="),
            let blob = Data(base64Encoded: String(location[range.upperBound...])
                .removingPercentEncoding ?? String(location[range.upperBound...])),
            let decoded = String(data: blob, encoding: .utf8)
        else { throw MoodleError.noRedirect(location) }

        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 3 else { throw MoodleError.noRedirect(location) }
        return (token: parts[1], privateToken: parts[2])
    }

    /// `webservice/rest/server.php` - Moodle's own long-lived REST API,
    /// confirmed to need no `sesskey`, no cookies, just the token, unlike
    /// the AJAX endpoint `PortalLMS` uses from inside a logged-in page.
    static func dueDates(wstoken: String) async throws -> [Deadline] {
        var components = URLComponents(
            url: lmsBase.appendingPathComponent("webservice/rest/server.php"), resolvingAgainstBaseURL: false
        )!
        let now = Int(Date().timeIntervalSince1970)
        components.queryItems = [
            URLQueryItem(name: "wstoken", value: wstoken),
            URLQueryItem(name: "wsfunction", value: "core_calendar_get_action_events_by_timesort"),
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "timesortfrom", value: String(now)),
            URLQueryItem(name: "limitnum", value: "50"),
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MoodleError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct Exception: Decodable { var exception: String?; var message: String? }
        if let err = try? JSONDecoder().decode(Exception.self, from: data), err.exception != nil {
            throw MoodleError.apiError(err.message ?? err.exception ?? "unknown")
        }

        struct Event: Decodable {
            var name: String
            var course: Course
            var timesort: Int?
            var modulename: String?
            var url: String?
            struct Course: Decodable { var fullname: String }
        }
        struct Payload: Decodable { var events: [Event] }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            let body = String(data: data.prefix(1000), encoding: .utf8) ?? "<binary>"
            throw MoodleError.decodeFailed(body)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return payload.events.compactMap { e -> Deadline? in
            guard let ts = e.timesort else { return nil }
            return Deadline(
                title: e.name, course: e.course.fullname,
                due: iso.string(from: Date(timeIntervalSince1970: TimeInterval(ts))),
                kind: e.modulename ?? "assign", url: e.url ?? ""
            )
        }
    }
}

/// Keychain storage for the Moodle wstoken/privatetoken pair - long-lived,
/// unlike `PortalAuth.Credentials`, so there's no refresh dance here at all;
/// a stored token is used until Moodle itself rejects it.
enum MoodleTokenStore {
    private static let service = "today.moodle-token"
    private static let account = "lms"

    struct Saved: Codable {
        var token: String
        var privateToken: String
    }

    static func load() -> Saved? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
