import SwiftUI

/// A tapped deadline, resolved at tap time from the webservice (course/teacher
/// carried over from the `Deadline` the webview already scraped).
struct LmsLink: Identifiable {
    let id = UUID()
    let url: URL
    let course: String?
    let teacher: String?
}

/// The assignment or quiz, shown natively - the way the official app does it, no
/// page load and no login. Fetched with the stored Moodle token; anything it
/// cannot render (submitting, taking the quiz) hands off to the webview via
/// `openPage`. Falls straight to `openPage` when the token is gone or the fetch
/// comes back empty, so a tap is never a dead end.
struct LmsDetailView: View {
    let link: LmsLink
    /// The full page in the webview (autologin) - also where you submit or attempt.
    let openPage: (URL) -> Void
    /// A token-bearing attachment URL in the webview - opens without a session.
    let openFile: (URL) -> Void
    /// Injected in `-demo` so the screen can be shot without a login; nil fetches.
    var preview: LmsDetail? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var detail: LmsDetail?
    @State private var phase: Phase = .loading

    private enum Phase { case loading, ready, failed }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    failure
                case .ready:
                    if let d = detail { content(d) } else { failure }
                }
            }
            .navigationTitle(detail?.kind == "quiz" ? "Quiz" : "Assignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Backdrop().ignoresSafeArea())
        }
        .task { await load() }
    }

    // MARK: - States

    private func content(_ d: LmsDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(d)
                if !d.descriptionText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details").r(12.5, .semibold)
                            .textCase(.uppercase).kerning(0.6).foregroundStyle(Color.ink3)
                        Text(d.descriptionText)
                            .r(15, .regular)
                            .foregroundStyle(Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .slab(.sur, radius: 24, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                }
                if !d.attachments.isEmpty { attachments(d.attachments) }
                openButton(d)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private func header(_ d: LmsDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(d.title)
                .r(22, .bold).kerning(-0.3)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(d.teacher.map { "\(d.course) · \($0)" } ?? d.course)
                .r(14, .medium).foregroundStyle(Color.ink3)
            HStack(spacing: 10) {
                if let due = d.due { chip(dueText(due), tint: dueTint(due)) }
                if let s = d.status { chip(s, tint: statusTint(s)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
    }

    private func attachments(_ files: [LmsDetail.Attachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(files.count == 1 ? "Attachment" : "\(files.count) attachments")
                .r(12.5, .semibold)
                .textCase(.uppercase).kerning(0.6).foregroundStyle(Color.ink3)
            VStack(spacing: 10) {
                ForEach(files) { f in
                    Button { openFile(f.url) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "paperclip").r(14, .semibold).foregroundStyle(Color.ink3)
                            Text(f.name).r(15, .medium).foregroundStyle(Color.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").r(12, .semibold).foregroundStyle(Color.ink3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableCard)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 24, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
    }

    private func openButton(_ d: LmsDetail) -> some View {
        Button {
            dismiss()
            openPage(d.pageURL)
        } label: {
            HStack(spacing: 8) {
                Text(d.kind == "quiz" ? "Open to attempt" : "Open full page")
                    .r(15.5, .semibold)
                Image(systemName: "safari").r(14, .semibold)
            }
            .foregroundStyle(Color.mint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .glassy(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var failure: some View {
        VStack(spacing: 16) {
            Text("Couldn't load this here.")
                .r(16, .semibold).foregroundStyle(Color.ink)
            Button {
                dismiss()
                openPage(link.url)
            } label: {
                Text("Open in LMS").r(15.5, .semibold).foregroundStyle(Color.mint)
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .glassy(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Load

    private func load() async {
        if let preview {
            detail = preview
            phase = .ready
            return
        }
        guard let saved = MoodleTokenStore.load() else { phase = .failed; return }
        let d = await PortalMoodle.detail(
            wstoken: saved.token, pageURL: link.url, course: link.course, teacher: link.teacher
        )
        detail = d
        phase = d == nil ? .failed : .ready
    }

    // MARK: - Formatting

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .r(13, .semibold).foregroundStyle(tint)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .glassy(Capsule())
    }

    private func dueText(_ date: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        let clock = LmsDetailView.time.string(from: date)
        switch n {
        case ..<0: return n == -1 ? "Due yesterday" : "Due \(-n)d ago"
        case 0: return "Due today · \(clock)"
        case 1: return "Due tomorrow · \(clock)"
        case 2...13: return "Due in \(n) days · \(LmsDetailView.day.string(from: date))"
        default: return "Due \(LmsDetailView.day.string(from: date))"
        }
    }

    private func dueTint(_ date: Date) -> Color {
        let n = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        if n < 0 { return Color.coral }
        if n <= 1 { return Color.amber }
        return Color.ink2
    }

    private func statusTint(_ s: String) -> Color {
        let low = s.lowercased()
        if low.hasPrefix("graded") || low == "submitted" || low.contains("attempt") { return Color.mint }
        if low.hasPrefix("not ") { return Color.amber }
        return Color.ink2
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM, h:mm a")
        return f
    }()
}
