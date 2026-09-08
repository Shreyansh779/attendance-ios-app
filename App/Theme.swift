import SwiftUI

/// Minimal, nothing sharp. Corners are never under 18, there are no borders or
/// hairline rules anywhere, and separation is carried by space and tone. The
/// typeface is rounded too, so the letterforms do not fight the shapes.
extension Color {
    init(_ hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static let bg = Color(0x191C23)
    static let sur = Color(0x22262F)
    static let surDim = Color(0x1E2129)
    static let surLive = Color(0x2C4B3E)
    static let surVirtual = Color(0x332A38)
    static let surLow = Color(0x3A2C2B)
    static let drawerBG = Color(0x1E222A)
    static let track = Color(0x2C313C)

    static let ink = Color(0xEDEFF3)
    static let ink2 = Color(0x9AA3B3)
    static let ink3 = Color(0x7D8698)
    static let ink4 = Color(0x5C6474)

    static let mint = Color(0x6FD4A6)
    static let mintHi = Color(0x8BE3B8)
    static let mintDim = Color(0x6FBF9A)
    static let coral = Color(0xF08A70)
    static let warnBG = Color(0x33302A)
    static let warnInk = Color(0xE8CE9C)
}

extension Font {
    static func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A soft slab. Everything in the app is one of these or a capsule.
struct Slab: ViewModifier {
    var fill: Color = .sur
    var radius: CGFloat = 24
    var padding: EdgeInsets = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func slab(_ fill: Color = .sur, radius: CGFloat = 24, pad: EdgeInsets? = nil) -> some View {
        modifier(
            Slab(
                fill: fill,
                radius: radius,
                padding: pad ?? EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
            )
        )
    }
}

/// Progress toward the threshold. Capsule, so there is nothing to line.
struct Meter: View {
    let pct: Double
    let low: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule()
                    .fill(low ? Color.coral : Color.mint)
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}
