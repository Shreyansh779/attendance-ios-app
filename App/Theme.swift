import SwiftUI
import UIKit

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

    /// Dark value first, because this app was designed dark-first and that is
    /// still the one anyone looks at.
    ///
    /// Every pair below was solved rather than picked: each ink clears WCAG AA
    /// (4.5:1) against every surface in its own scheme, and each step of the
    /// ramp stays ~1.4x apart in luminance so the hierarchy survives the floor.
    init(_ dark: UInt32, _ light: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    static let bg = Color(0x191C23, 0xF2F4F8)
    static let sur = Color(0x22262F, 0xFFFFFF)
    static let surDim = Color(0x1E2129, 0xE9ECF2)
    static let surLive = Color(0x2C4B3E, 0xE4F4EC)
    static let surVirtual = Color(0x332A38, 0xF4EFF7)
    static let surLow = Color(0x3A2C2B, 0xFBEDEA)
    static let track = Color(0x2C313C, 0xDDE1E9)

    static let ink = Color(0xEDEFF3, 0x11151C)
    static let ink2 = Color(0xC4D0E4, 0x3D424D)
    static let ink3 = Color(0xA9B2C4, 0x4F5664)
    static let ink4 = Color(0x8F97A6, 0x626B7C)

    static let mint = Color(0x6FD4A6, 0x3D755C)
    static let mintHi = Color(0x8BE3B8, 0x2F6B4E)
    static let mintDim = Color(0x6FBF9A, 0x4A806A)
    static let coral = Color(0xF08A70, 0x9B5948)
    /// The middle state. Before this there was only "fine" and "alarm", so a
    /// term where every subject is short rendered as an unbroken wall of red -
    /// and when everything is an alarm, nothing is.
    static let amber = Color(0xE8B14C, 0x85652C)
    static let violet = Color(0xE58FC0, 0x8A4A72)
    static let warnBG = Color(0x33302A, 0xFCF3E0)
    static let warnInk = Color(0xE8CE9C, 0x6B5320)
    /// Text that sits on top of a mint-filled control.
    static let onAccent = Color(0x1B2C24, 0xFFFFFF)

    /// How loudly a subject should shout.
    static func urgencyTint(_ u: Urgency) -> Color {
        switch u {
        case .fine: return .mintHi
        case .behind: return .amber
        case .critical: return .coral
        }
    }
}

extension UIColor {
    fileprivate convenience init(_ hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
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
    /// Fixed size. Only for contexts that need a `Font` value rather than a
    /// view modifier; prefer `View.r(_:_:)`, which scales.
    static func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The rounded system font at `size`, scaled by the reader's text-size setting.
///
/// `Font.system(size:)` ignores Dynamic Type entirely, so every size in this app
/// used to be a fixed point value — the one accessibility gap left after the
/// contrast work. `@ScaledMetric` is the piece that both scales the number and
/// tells SwiftUI to re-evaluate when the setting changes.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .rounded))
    }
}

extension View {
    func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight))
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
    /// A colour rather than a bool, because "behind" and "cannot recover" are
    /// not the same state and should not look the same.
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}
