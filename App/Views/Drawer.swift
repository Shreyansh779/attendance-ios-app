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
    let onRefresh: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Text(initials)
                    .font(.r(17, .bold))
                    .foregroundStyle(Color.mintHi)
                    .frame(width: 44, height: 44)
                    .background(Color.surLive, in: Circle())
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
                        route = r
                        close()
                    } label: {
                        NavRow(route: r, selected: route == r, badge: badge(r))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onRefresh) {
                    HStack(spacing: 13) {
                        Circle()
                            .strokeBorder(Color.ink2, lineWidth: 2.5)
                            .frame(width: 16, height: 16)
                        Text("Refresh from portal").font(.r(16, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sur, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
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
        case .timetable: return day.isEmpty ? nil : "\(day.count)"
        case .attendance:
            return summary.subjects.isEmpty ? nil : "\(Int(summary.overall.pct.rounded()))%"
        }
    }

    private var foot: some View {
        let worst = summary.failing.first
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
