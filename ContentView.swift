import SwiftUI
import WidgetKit

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var stamp = ""
    @State private var writeResult: (defaults: Bool, file: Bool)?
    @State private var readBack: (defaults: String?, file: String?) = (nil, nil)

    private let facts = Probe.profileFacts()

    var body: some View {
        NavigationStack {
            List {
                Section("Verdict") {
                    verdict
                }

                Section("Provisioning profile") {
                    row("Profile present", facts.found ? "yes" : "NO")
                    row("App ID", facts.applicationIdentifier ?? "unreadable")
                    row("Kind", facts.found
                        ? (facts.isWildcard ? "wildcard" : "explicit")
                        : "unknown")
                    row("App Groups entitlement",
                        facts.appGroups.map { $0.isEmpty ? "present but empty" : $0.joined(separator: ", ") }
                            ?? "ABSENT")
                    row("Team", facts.teamIDs.first ?? "none")
                    if let e = facts.expires {
                        row("Expires", e.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Section("Runtime") {
                    row("Bundle ID", Probe.bundleID)
                    row("Group ID", Probe.groupID)
                    row("Container URL",
                        Probe.containerURL == nil ? "nil — group NOT granted" : "resolved")
                }

                Section("Write test") {
                    Button("Write timestamp") { writeStamp() }
                    if let r = writeResult {
                        row("UserDefaults write", r.defaults ? "ok" : "FAILED")
                        row("File write", r.file ? "ok" : "FAILED")
                    }
                    if !stamp.isEmpty {
                        row("Wrote", stamp)
                    }
                }

                Section("Read back (in-app)") {
                    Button("Read") { readBack = Probe.read() }
                    row("UserDefaults", readBack.defaults ?? "nil")
                    row("File", readBack.file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil")
                }

                Section {
                    Text("Now add the widget to your home screen. If it shows the same timestamp, App Groups work under this signing setup. If it says no data, they do not.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("App Group Probe")
        }
        .onAppear { readBack = Probe.read() }
    }

    private var verdict: some View {
        let hasEnt = facts.appGroups?.contains(Probe.groupID) ?? false
        let hasContainer = Probe.containerURL != nil

        let (text, color): (String, Color) = {
            if !facts.found {
                return ("No provisioning profile in the bundle. Unsigned build — sideload it first.", .orange)
            }
            if !hasEnt && !hasContainer {
                return ("App Groups not granted. The entitlement is missing from the profile, so the widget cannot read anything.", .red)
            }
            if hasEnt && !hasContainer {
                return ("Entitlement is in the profile but the container will not resolve. Group ID mismatch, or the sideloader rewrote the bundle ID.", .orange)
            }
            if !hasEnt && hasContainer {
                return ("Container resolves without the entitlement appearing in the profile. Unexpected — check the widget, which is signed separately.", .orange)
            }
            return ("App Groups granted and the container resolves. Write a timestamp, then check the widget.", .green)
        }()

        return Text(text)
            .font(.callout)
            .foregroundStyle(color)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
            Spacer(minLength: 12)
            Text(v)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(.footnote, design: .monospaced))
    }

    private func writeStamp() {
        let s = Date().formatted(date: .omitted, time: .standard)
        stamp = s
        writeResult = Probe.write(s)
        readBack = Probe.read()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
