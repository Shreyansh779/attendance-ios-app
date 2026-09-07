import WidgetKit
import SwiftUI

// The widget is a separate process with its own sandbox and its own
// embedded.mobileprovision, so it reports its own view of the entitlement
// rather than trusting the app's. Divergence between the two is the single
// most useful signal this probe can produce.
struct Entry: TimelineEntry {
    let date: Date
    let stamp: String?
    let containerOK: Bool
    let entitlementPresent: Bool
    let wildcard: Bool
}

struct Provider: TimelineProvider {
    private func snapshot() -> Entry {
        let facts = Probe.profileFacts()
        let read = Probe.read()
        return Entry(
            date: Date(),
            stamp: read.defaults ?? read.file?.trimmingCharacters(in: .whitespacesAndNewlines),
            containerOK: Probe.containerURL != nil,
            entitlementPresent: facts.appGroups?.contains(Probe.groupID) ?? false,
            wildcard: facts.isWildcard
        )
    }

    func placeholder(in context: Context) -> Entry { snapshot() }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(snapshot())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [snapshot()], policy: .after(Date().addingTimeInterval(60))))
    }
}

struct ProbeWidgetView: View {
    var entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.stamp == nil ? "NO DATA" : "READS OK")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(entry.stamp == nil ? .red : .green)

            Text(entry.stamp ?? "widget cannot see the group")
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)

            Spacer(minLength: 2)

            Text("container \(entry.containerOK ? "ok" : "nil")")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("entitlement \(entry.entitlementPresent ? "present" : "absent")")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.wildcard ? "wildcard app id" : "explicit app id")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProbeWidget", provider: Provider()) { entry in
            ProbeWidgetView(entry: entry)
        }
        .configurationDisplayName("App Group Probe")
        .description("Shows whether the widget can read the app's shared container.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
