import SwiftUI

/// This semester's courses, and what your own teachers have put in them.
///
/// A course on this Moodle is taught by several teachers to several batches,
/// each with a section named after the teacher, and the sections that are not
/// yours are marked invisible to you. The scraper filters on that, so what
/// arrives here is already only your material — this screen just lays it out.
struct LmsView: View {
    let courses: [LmsCourse]
    /// Opens the link inside the app's own webview, which is the only place
    /// the Moodle session exists.
    let onOpen: (String) -> Void

    private var stocked: [LmsCourse] { courses.filter { !$0.items.isEmpty } }
    private var bare: [LmsCourse] { courses.filter { $0.items.isEmpty } }

    // A scroll view, even when three courses would fit. A navigation bar
    // insets a scroll view it finds below it and lays a plain stack out from
    // the top of the safe area instead - which is how the large title ends up
    // drawn over the first card.
    var body: some View {
        ScrollView(showsIndicators: false) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(stocked, id: \.id) { c in
                NavigationLink {
                    CourseView(course: c, onOpen: onOpen)
                } label: {
                    CourseRow(course: c)
                }
                .buttonStyle(.pressableCard)
            }

            // Kept, rather than hidden: a course with nothing in it is an
            // answer, and dropping it silently reads as the scrape having
            // missed something.
            if !bare.isEmpty {
                Text("Nothing posted yet")
                    .r(12.5, .semibold)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(Color.ink3)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bare, id: \.id) { c in
                        Text(c.name)
                            .r(15, .medium)
                            .foregroundStyle(Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .slab(.sur, radius: 24, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }
}

private struct CourseRow: View {
    let course: LmsCourse

    /// Who put the material there. Most sections are named after a teacher,
    /// so the distinct ones are usually the people teaching you.
    private var teachers: String {
        var seen: [String] = []
        for i in course.items where !seen.contains(i.group) { seen.append(i.group) }
        return seen.prefix(2).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .r(17, .semibold)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text(teachers)
                    .r(13, .medium)
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(course.items.count)")
                .r(15, .bold)
                .foregroundStyle(Color.ink2)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(.sur, radius: 26, pad: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .accessibilityElement(children: .combine)
    }
}

/// One course, its material grouped the way the course page groups it.
private struct CourseView: View {
    let course: LmsCourse
    let onOpen: (String) -> Void

    private struct Chunk: Identifiable {
        /// The section's own title, which is unique within a course.
        let id: String
        let items: [LmsItem]
    }

    /// Sections in the order the scraper found them, which is the order the
    /// course page shows — first come the teachers, then the units.
    private var groups: [Chunk] {
        var order: [String] = []
        var byGroup: [String: [LmsItem]] = [:]
        for i in course.items {
            if byGroup[i.group] == nil { order.append(i.group) }
            byGroup[i.group, default: []].append(i)
        }
        return order.map { Chunk(id: $0, items: byGroup[$0] ?? []) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.id)
                            .r(12.5, .semibold)
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .foregroundStyle(Color.ink3)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 13) {
                            ForEach(group.items, id: \.self) { item in
                                Button {
                                    onOpen(item.url)
                                } label: {
                                    Row(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .slab(.sur, radius: 28, pad: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 90)
        }
        .background(Color.clear)
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Row: View {
        let item: LmsItem

        /// Moodle's own module names, as icons. Anything unrecognised gets a
        /// document, which is what most of them are.
        private var symbol: String {
            switch item.kind.lowercased() {
            case "assignment": return "tray.and.arrow.up"
            case "quiz": return "checkmark.circle"
            case "url": return "link"
            case "folder": return "folder"
            case "page": return "doc.richtext"
            case "forum": return "bubble.left.and.bubble.right"
            case "video", "lesson": return "play.rectangle"
            default: return "doc"
            }
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .r(15.5, .semibold)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(item.kind)
                        .r(13, .medium)
                        .foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }
}
