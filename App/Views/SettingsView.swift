import SwiftUI
import UIKit

/// The few things worth choosing, and the diagnostics.
///
/// This was a stock `Form`, which is the right answer in an app that looks
/// like the rest of iOS and the wrong one here: grouped rows on system grey,
/// with a blue tint and a wheel picker, in an app made of glass and ink. Same
/// controls, same behaviour, built out of the same parts as every other
/// screen.
struct SettingsView: View {
    @AppStorage(Notify.enabledKey) private var remindersOn = true
    @AppStorage(Notify.leadKey) private var lead = Notify.defaultLead

    let weekDays: Int
    let weekDiag: String?
    let registerRows: Int
    let attDiag: String?
    let dueCount: Int
    let courseCount: Int
    let lmsDiag: String?
    let age: String?
    /// Re-runs the schedule, because changing the lead time or switching
    /// reminders off should take effect now rather than at the next refresh.
    let onSettingsChanged: () -> Void

    @State private var testResult: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let leads = [10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    reminders
                    data
                    if weekDays <= 1, let weekDiag {
                    diagnostic("Timetable", weekDiag, "The weekly scrape returned little or nothing.")
                }
                if dueCount == 0, courseCount == 0, let lmsDiag {
                    diagnostic(
                        "LMS",
                        lmsDiag,
                        "Nothing came back from the LMS, so Due and the LMS tab are empty."
                    )
                }
                if registerRows == 0, let attDiag {
                    diagnostic(
                        "Register",
                        attDiag,
                        "The day-by-day attendance search came back empty, so This week and "
                            + "Day by day are hidden."
                    )
                }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Backdrop())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .r(16, .semibold)
                        .foregroundStyle(Color.ink)
                }
            }
            .onChange(of: remindersOn) { _, _ in onSettingsChanged() }
            .onChange(of: lead) { _, _ in onSettingsChanged() }
        }
    }

    // MARK: - Reminders

    private var reminders: some View {
        Card(
            "Reminders",
            note: "Scheduled on this phone, never on a server. iOS holds 64 at a time, "
                + "so the queue is topped up on every refresh."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: $remindersOn) {
                    Text("Before each class").r(16, .medium)
                }
                .tint(Color.ink)
                .padding(.vertical, 14)

                if remindersOn {
                    Rule()
                    VStack(alignment: .leading, spacing: 11) {
                        Text("How early")
                            .r(13, .medium)
                            .foregroundStyle(Color.ink3)
                        // A row of five, rather than a wheel: every option is
                        // on screen and one tap away, and the thumb can be
                        // dragged across them.
                        SlideBar(items: Self.leads, selection: $lead) { m, on in
                            Text("\(m)")
                                .r(15, .semibold)
                                .foregroundStyle(on ? Color.onInk : Color.ink2)
                                .padding(.vertical, 9)
                                .accessibilityLabel("\(m) minutes before")
                                .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                        .padding(4)
                        .background(Color.well, in: Capsule())
                    }
                    .padding(.vertical, 14)

                    Rule()
                    Button {
                        Task { testResult = await Notify.test() }
                    } label: {
                        HStack {
                            Text("Send a test reminder").r(16, .medium)
                            Spacer(minLength: 0)
                            Image(systemName: "bell.badge")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.ink3)
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableCard)

                    if let testResult {
                        Text(testResult)
                            .p(13)
                            .foregroundStyle(Color.ink3)
                            .padding(.bottom, 14)
                            .transition(.soft)
                    }
                }
            }
            .animation(Motion.ui.reduced(reduceMotion), value: remindersOn)
            .animation(Motion.ui.reduced(reduceMotion), value: testResult)
        }
    }

    // MARK: - Data

    private var data: some View {
        Card("Data") {
            VStack(spacing: 0) {
                if let age {
                    Line(name: "Last read", value: age)
                    Rule()
                }
                Line(name: "Days cached", value: "\(weekDays)")
                Rule()
                Line(name: "LMS courses", value: "\(courseCount)")
                Rule()
                Line(name: "Version", value: SettingsView.version)
            }
        }
    }

    /// "1.1 (94)" - the marketing version and the CI run that built it.
    private static let version: String = {
        let b = Bundle.main.infoDictionary
        let short = b?["CFBundleShortVersionString"] as? String ?? "?"
        let build = b?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    // MARK: - Diagnostic

    /// Only worth showing when a scrape came back thin — otherwise it is noise
    /// about a thing that is working.
    private func diagnostic(_ name: String, _ text: String, _ why: String) -> some View {
        Card(
            "\(name) diagnostic",
            note: why + " This is what the page actually did."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .r(14, .semibold)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassy(Capsule(), soft: false)
                }
                .buttonStyle(.pressable)
            }
            .padding(.vertical, 15)
        }
    }

    // MARK: - Pieces

    /// A titled card, with an optional line of small print under it — the two
    /// halves of what `Section(header:footer:)` used to give for free.
    private struct Card<Content: View>: View {
        let title: String
        let note: String?
        let content: Content

        init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.note = note
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .r(12, .semibold)
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(Color.ink3)
                    .padding(.leading, 4)

                content
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassy(RoundedRectangle(cornerRadius: 24, style: .continuous))

                if let note {
                    Text(note)
                        .p(12.5)
                        .foregroundStyle(Color.ink4)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// The hairline between two rows of one card. The only rule in the app,
    /// and it exists because a gap alone cannot say "same card, next thing".
    private struct Rule: View {
        var body: some View {
            Rectangle()
                .fill(Color.edge)
                .frame(height: 0.8)
                .accessibilityHidden(true)
        }
    }

    private struct Line: View {
        let name: String
        let value: String

        var body: some View {
            HStack {
                Text(name).r(16, .medium).foregroundStyle(Color.ink)
                Spacer(minLength: 12)
                Text(value).r(16, .regular).foregroundStyle(Color.ink3)
            }
            .padding(.vertical, 15)
        }
    }
}
