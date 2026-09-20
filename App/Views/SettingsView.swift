import SwiftUI
import UIKit

/// The few things worth choosing, and the diagnostics.
///
/// Both used to be wedged into the bottom of the Attendance screen, which is
/// where numbers live, not controls. A `Form` is also the first one in this
/// app — the platform's own answer to "a short list of settings", rather than
/// another hand-built stack of slabs.
struct SettingsView: View {
    @AppStorage(Notify.enabledKey) private var remindersOn = true
    @AppStorage(Notify.leadKey) private var lead = Notify.defaultLead

    let weekDays: Int
    let weekDiag: String?
    let age: String?
    /// Re-runs the schedule, because changing the lead time or switching
    /// reminders off should take effect now rather than at the next refresh.
    let onSettingsChanged: () -> Void

    @State private var testResult: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Before each class", isOn: $remindersOn)

                    if remindersOn {
                        Picker("How early", selection: $lead) {
                            ForEach([10, 15, 30, 45, 60], id: \.self) { m in
                                Text("\(m) min").tag(m)
                            }
                        }
                    }

                    Button("Send a test reminder") {
                        Task { testResult = await Notify.test() }
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text(
                        "Reminders are scheduled on this phone — nothing is sent to a server. "
                            + "iOS holds at most 64 at a time, so the queue is topped up on every refresh."
                    )
                }
                // Glass instead of the stock grouped fill, so the sections
                // belong to the same material as every other card.
                .listRowBackground(GlassBG(shape: Rectangle(), soft: false))

                Section("Data") {
                    if let age {
                        LabeledContent("Last read", value: age)
                    }
                    LabeledContent("Days cached", value: "\(weekDays)")
                }
                .listRowBackground(GlassBG(shape: Rectangle(), soft: false))

                // Only worth showing when the weekly scrape came back thin —
                // otherwise it is noise about a thing that is working.
                if weekDays <= 1, let weekDiag {
                    Section {
                        Text(weekDiag)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy diagnostic") {
                            UIPasteboard.general.string = weekDiag
                        }
                    } header: {
                        Text("Timetable diagnostic")
                    } footer: {
                        Text("The weekly scrape returned little or nothing. This is what the page actually did.")
                    }
                    .listRowBackground(GlassBG(shape: Rectangle(), soft: false))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: remindersOn) { _, _ in onSettingsChanged() }
            .onChange(of: lead) { _, _ in onSettingsChanged() }
        }
    }
}
