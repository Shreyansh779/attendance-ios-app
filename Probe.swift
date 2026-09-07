import Foundation

/// Everything the probe needs to answer one question: did this binary come out
/// of signing with a usable App Group entitlement?
///
/// The interesting part is `profile`. An `.app` (and each `.appex` inside it)
/// carries its own `embedded.mobileprovision`, which is a CMS-signed blob with
/// a plain XML plist sitting inside it. Reading that tells us what the
/// provisioning profile actually granted, rather than what we asked for in the
/// entitlements file. That distinction is the whole point: a sideloader can
/// strip or rewrite entitlements, and the profile is the record of what stuck.
enum Probe {

    /// Single-sourced from the build setting, so the app and the widget cannot
    /// drift apart on the group identifier.
    static var groupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String) ?? "group.unknown"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }

    // MARK: - Provisioning profile

    struct ProfileFacts {
        var found: Bool
        var appIDName: String?
        /// e.g. "ABCDE12345.com.you.probe" — a trailing "*" means wildcard.
        var applicationIdentifier: String?
        /// Nil means the entitlement is absent from the profile entirely.
        var appGroups: [String]?
        var teamIDs: [String]
        var expires: Date?

        var isWildcard: Bool {
            applicationIdentifier?.hasSuffix("*") ?? false
        }
    }

    static func profileFacts(in bundle: Bundle = .main) -> ProfileFacts {
        guard
            let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url)
        else {
            return ProfileFacts(found: false, appIDName: nil, applicationIdentifier: nil,
                                appGroups: nil, teamIDs: [], expires: nil)
        }

        // Carve the XML plist out of the CMS wrapper.
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8))
        else {
            return ProfileFacts(found: true, appIDName: nil, applicationIdentifier: nil,
                                appGroups: nil, teamIDs: [], expires: nil)
        }

        let xml = data[start.lowerBound..<end.upperBound]
        let parsed = try? PropertyListSerialization.propertyList(
            from: xml, options: [], format: nil
        )

        guard let root = parsed as? [String: Any] else {
            return ProfileFacts(found: true, appIDName: nil, applicationIdentifier: nil,
                                appGroups: nil, teamIDs: [], expires: nil)
        }

        let ents = root["Entitlements"] as? [String: Any]

        return ProfileFacts(
            found: true,
            appIDName: root["AppIDName"] as? String,
            applicationIdentifier: ents?["application-identifier"] as? String,
            appGroups: ents?["com.apple.security.application-groups"] as? [String],
            teamIDs: root["TeamIdentifier"] as? [String] ?? [],
            expires: root["ExpirationDate"] as? Date
        )
    }

    // MARK: - Does the container actually work?

    /// `UserDefaults(suiteName:)` returns non-nil even without the entitlement,
    /// so it proves nothing on its own. The container URL is the honest check —
    /// it comes back nil when the sandbox has not granted the group.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    static let stampKey = "probe.stamp"

    /// Writes through both paths. If they disagree we want to see that.
    static func write(_ value: String) -> (defaults: Bool, file: Bool) {
        var viaDefaults = false
        if let d = defaults {
            d.set(value, forKey: stampKey)
            viaDefaults = d.string(forKey: stampKey) == value
        }

        var viaFile = false
        if let dir = containerURL {
            let f = dir.appendingPathComponent("stamp.txt")
            do {
                try value.write(to: f, atomically: true, encoding: .utf8)
                viaFile = (try? String(contentsOf: f, encoding: .utf8)) == value
            } catch {
                viaFile = false
            }
        }
        return (viaDefaults, viaFile)
    }

    static func read() -> (defaults: String?, file: String?) {
        let d = defaults?.string(forKey: stampKey)
        var f: String?
        if let dir = containerURL {
            f = try? String(contentsOf: dir.appendingPathComponent("stamp.txt"), encoding: .utf8)
        }
        return (d, f)
    }
}
