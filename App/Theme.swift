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

    // A four-step ramp where even the dimmest step clears WCAG AA (4.5:1) on
    // every neutral surface, and each step stays ~1.4x brighter than the one
    // below so the hierarchy still reads. The old ramp bottomed out at 2.71:1
    // - the "past class" rows were genuinely unreadable, not just quiet.
    static let ink = Color(0xEDEFF3)  // 11.58:1
    static let ink2 = Color(0xC4D0E4)  // 8.56:1
    static let ink3 = Color(0xA9B2C4)  // 6.26:1
    static let ink4 = Color(0x8F97A6)  // 4.54:1 - the floor

    static let mint = Color(0x6FD4A6)
    static let mintHi = Color(0x8BE3B8)
    static let mintDim = Color(0x6FBF9A)
    static let coral = Color(0xF08A70)
    static let warnBG = Color(0x33302A)
    static let warnInk = Color(0xE8CE9C)
}

// MARK: - Motion

/// Timing decided once, here, rather than guessed at each call site.
///
/// The numbers are Apple's own, from Designing Fluid Interfaces: a drawer is
/// damping 0.8 / response 0.3, general UI is critically damped. SwiftUI's
/// `bounce` is `1 - damping`, so 0.8 damping is bounce 0.2. Bounce is only
/// earned where the gesture itself carried momentum - overshoot on something
/// that merely appeared reads as a wobble.
enum Motion {
    /// Panels and sheets: the one place bounce belongs.
    static let panel = Animation.spring(duration: 0.3, bounce: 0.2)
    /// Everything else. Arrives and stops.
    static let ui = Animation.spring(duration: 0.35, bounce: 0)
    /// Press feedback. Short enough to read as instant rather than as motion.
    static let press = Animation.spring(duration: 0.16, bounce: 0)
    /// The stand-in when the system asks for less motion. Still explains the
    /// change; moves nothing across the screen.
    static let gentle = Animation.easeOut(duration: 0.18)
}

extension Animation {
    /// Swaps in the gentle cross-fade when Reduce Motion is on, so call sites
    /// read `Motion.panel.reduced(reduceMotion)` and never have to remember
    /// which animations are safe.
    func reduced(_ reduce: Bool) -> Animation { reduce ? Motion.gentle : self }
}

// MARK: - Press

/// Every pressable thing acknowledges the touch, on touch *down*.
///
/// The app used `.plain` throughout, which draws no press state at all: a tap
/// produced no acknowledgement until the screen itself changed, which is the
/// moment directness falls off a cliff. Scale is deliberately small - large
/// surfaces need less of it than small ones to read as the same movement.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressEffect(configuration: configuration, scale: scale)
    }

    /// Named PressEffect, not Body: ButtonStyle has an associated type called
    /// Body, so a nested type of that name is taken as its witness and has to
    /// match the outer access level.
    ///
    /// A ButtonStyle is not a View, so @Environment on the style itself is
    /// never populated - it would read false forever and quietly ignore
    /// Reduce Motion. The nested view is what can actually see it.
    private struct PressEffect: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
                .opacity(configuration.isPressed ? 0.82 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Small controls: pills, arrows, text buttons.
    static var pressable: PressableStyle { PressableStyle() }
    /// Full-width rows and cards, where the same ratio reads as a bigger jump.
    static var pressableCard: PressableStyle { PressableStyle(scale: 0.985) }
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
