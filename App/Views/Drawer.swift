import SwiftUI
import UIKit

enum Route: String, CaseIterable {
    case today, timetable, attendance

    var title: String {
        switch self {
        case .today: return "Today"
        case .timetable: return "Timetable"
        case .attendance: return "Attendance"
        }
    }
}

struct Drawer: View {
    @Binding var route: Route
    let day: [Klass]
    let summary: Summary
    let snapshot: Snapshot?
    let student: String?
    /// `data:image/...;base64,` URI from the dashboard header.
    let photo: String?
    let weekDays: Int
    /// A read is already in flight; tapping refresh again would be a no-op.
    let busy: Bool
    /// Picking a route from the menu, as opposed to arriving at one
    /// programmatically. Kept separate from the `route` binding so the owner
    /// can tell the two apart - tapping "Today" here should drop any pinned
    /// class, while a timetable tap navigating to Today must keep it.
    let onSelect: (Route) -> Void
    let onRefresh: () -> Void
    let close: () -> Void

    /// Decoded once per render of the header rather than per frame.
    private var photoImage: UIImage? {
        guard let p = photo,
            let comma = p.firstIndex(of: ","),
            let data = Data(base64Encoded: String(p[p.index(after: comma)...]))
        else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                // The real photo when the dashboard gave us one, initials
                // otherwise.
                if let img = photoImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.r(17, .bold))
                        .foregroundStyle(Color.mintHi)
                        .frame(width: 44, height: 44)
                        .background(Color.surLive, in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(student ?? "Today").font(.r(16.5, .semibold)).lineLimit(1)
                    Text("UPES dashboard").font(.r(13, .medium)).foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 22)

            VStack(spacing: 7) {
                ForEach(Route.allCases, id: \.self) { r in
                    Button {
                        onSelect(r)
                        close()
                    } label: {
                        NavRow(route: r, selected: route == r, badge: badge(r))
                    }
                    .buttonStyle(.pressableCard)
                }

                Button(action: onRefresh) {
                    HStack(spacing: 13) {
                        Circle()
                            .strokeBorder(busy ? Color.ink4 : Color.ink2, lineWidth: 2.5)
                            .frame(width: 16, height: 16)
                        Text(busy ? "Reading from portal…" : "Refresh from portal")
                            .font(.r(16, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(busy ? Color.ink4 : Color.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sur, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.pressableCard)
                .disabled(busy)
                .padding(.top, 7)
            }

            Spacer(minLength: 20)

            foot
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.drawerBG)
        .clipShape(RoundedCorners(radius: 34, corners: [.topRight, .bottomRight]))
        // A floating layer should read as floating. Bigger surfaces carry a
        // deeper shadow than small ones - this is the largest in the app.
        .shadow(color: Color(0x05070A).opacity(0.45), radius: 34, x: 10, y: 0)
    }

    private var initials: String {
        guard let n = student else { return "·" }
        let parts = n.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "·" : letters.uppercased()
    }

    private func badge(_ r: Route) -> String? {
        switch r {
        case .today: return nil
        case .timetable: return nil
        case .attendance:
            return summary.subjects.isEmpty ? nil : "\(Int(summary.overall.pct.rounded()))%"
        }
    }

    private var foot: some View {
        let worst = summary.blocker
        return VStack(alignment: .leading, spacing: 8) {
            if summary.subjects.isEmpty {
                Text("Nothing saved yet. Tap refresh and log in.")
                    .font(.r(13.5, .medium))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(worst.map { "+\($0.budget.value)" } ?? "\(summary.overall.value)")
                    .font(.r(30, .bold))
                    .kerning(-1.2)
                    .foregroundStyle(worst == nil ? Color.mintHi : Color.coral)
                Text(
                    worst.map { "\($0.key) is below \(THRESHOLD)% and needs \($0.budget.value) in a row" }
                        ?? "classes you can skip across everything"
                )
                .font(.r(13.5, .medium))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
                if let s = snapshot {
                    Text(s.ageText).font(.r(12.5, .medium)).foregroundStyle(Color.ink4)
                }
                // Only shown when the weekly timetable did not come through, so
                // the failure is diagnosable instead of silent.
                if weekDays <= 1, let d = snapshot?.weekDiag {
                    Text("week: \(d)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.ink4)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    Button {
                        UIPasteboard.general.string = d
                    } label: {
                        Text("Copy diagnostic")
                            .font(.r(12, .semibold))
                            .foregroundStyle(Color.mintHi)
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 6)
                }
            }
        }
        .slab(.sur, radius: 24, pad: EdgeInsets(top: 17, leading: 19, bottom: 17, trailing: 19))
    }

    private struct NavRow: View {
        let route: Route
        let selected: Bool
        let badge: String?

        var body: some View {
            HStack(spacing: 13) {
                Glyph(route: route, on: selected)
                Text(route.title).font(.r(16, .semibold))
                Spacer(minLength: 0)
                if let b = badge {
                    Text(b)
                        .font(.r(14, .semibold))
                        .foregroundStyle(selected ? Color.mintDim : Color.ink3)
                }
            }
            .foregroundStyle(selected ? Color.mintHi : Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.surLive : Color.sur,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
    }

    private struct Glyph: View {
        let route: Route
        let on: Bool

        var body: some View {
            let c = on ? Color.mintHi : Color.ink2
            Group {
                switch route {
                case .today:
                    Circle().fill(c).frame(width: 16, height: 16)
                case .timetable:
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Circle().fill(c).frame(width: 7, height: 7)
                            Circle().fill(c).frame(width: 7, height: 7)
                        }
                        HStack(spacing: 3) {
                            Circle().fill(c).frame(width: 7, height: 7)
                            Circle().fill(c).frame(width: 7, height: 7)
                        }
                    }
                case .attendance:
                    HStack(alignment: .bottom, spacing: 3) {
                        Capsule().fill(c).frame(width: 4, height: 9)
                        Capsule().fill(c).frame(width: 4, height: 16)
                        Capsule().fill(c).frame(width: 4, height: 12)
                    }
                }
            }
            .frame(width: 22, height: 22)
        }
    }
}

/// Only the drawer needs asymmetric corners, so this stays local rather than
/// reaching for a whole shape library.
struct RoundedCorners: Shape {
    let radius: CGFloat
    let corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}
