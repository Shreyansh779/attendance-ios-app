import SwiftUI
import UIKit

/// Monochrome, glass, and quiet.
///
/// Nothing sharp: corners are never under 18 and there are no hairline rules
/// except the one pixel of light along the top of a glass edge. Colour is
/// spent only on urgency - every other surface is a material, and every other
/// mark is ink. Separation is carried by blur, space and tone.
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
    /// Every ink below clears WCAG AA (4.5:1) against its own ground in both
    /// schemes, and each step of the ramp stays ~1.4x apart in luminance so the
    /// hierarchy survives the floor.
    init(_ dark: UInt32, _ light: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    fileprivate static func adaptive(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: Ground

    static let bg = Color(0x111113, 0xF2F2F4)

    // MARK: Surfaces
    //
    // These are *tints*, not fills. Every one of them is laid over a material
    // rather than instead of it, so a card is glass first and a colour second.
    // An opaque card would have nothing to blur and the whole system would
    // collapse back into flat rectangles.

    static let sur = adaptive(UIColor(white: 1, alpha: 0.055), UIColor(white: 1, alpha: 0.55))
    static let surDim = adaptive(UIColor(white: 0, alpha: 0.16), UIColor(white: 0.55, alpha: 0.10))
    static let surLive = adaptive(
        UIColor(0x7FD9AE).withAlphaComponent(0.16), UIColor(0x2E7D5B).withAlphaComponent(0.13)
    )
    static let surVirtual = adaptive(
        UIColor(0xB9A8E0).withAlphaComponent(0.14), UIColor(0x6B5B95).withAlphaComponent(0.11)
    )
    static let surLow = adaptive(
        UIColor(0xF0917A).withAlphaComponent(0.15), UIColor(0xB8402A).withAlphaComponent(0.10)
    )
    static let track = adaptive(UIColor(white: 1, alpha: 0.13), UIColor(white: 0, alpha: 0.09))
    /// The groove a thumb slides in. Deliberately darker than any other
    /// surface: the thumb is ink, which in the dark scheme is nearly white,
    /// and a white thumb on pale glass is two whites arguing.
    static let well = adaptive(UIColor(white: 0, alpha: 0.40), UIColor(white: 0, alpha: 0.075))

    /// The one pixel of light along a glass edge, and the shadow that lifts it
    /// off the ground. Without both, a material reads as a grey rectangle.
    static let edge = adaptive(UIColor(white: 1, alpha: 0.10), UIColor(white: 1, alpha: 0.70))
    static let shade = adaptive(UIColor(white: 0, alpha: 0.44), UIColor(white: 0.40, alpha: 0.15))

    // MARK: Ink - the only accent

    static let ink = Color(0xF5F5F7, 0x131316)
    static let ink2 = Color(0xA8A8B3, 0x6B6B73)
    static let ink3 = Color(0x8E8E98, 0x74747C)
    static let ink4 = Color(0x82828A, 0x7C7C84)

    /// Text on top of an ink-filled control. Ink is the accent in this palette,
    /// so "on accent" is simply the ground it was cut out of.
    static let onInk = Color(0x131316, 0xFFFFFF)

    // MARK: Urgency - the only colour

    static let mint = Color(0x7FD9AE, 0x2E7D5B)
    static let mintHi = Color(0x8FE0B8, 0x28714F)
    static let mintDim = Color(0x6FBF9A, 0x3D755C)
    static let coral = Color(0xF0917A, 0xB8402A)
    /// The middle state. Before this there was only "fine" and "alarm", so a
    /// term where every subject is short rendered as an unbroken wall of red -
    /// and when everything is an alarm, nothing is.
    static let amber = Color(0xF0C060, 0x8A5E14)
    static let violet = Color(0xB9A8E0, 0x6B5B95)
    static let warnInk = Color(0xE0CCA4, 0x6F5518)
    /// Text that sits on top of a filled control.
    static let onAccent = Color(0x131316, 0xFFFFFF)

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
/// Nothing in this app overshoots. Bounce is earned by a gesture that carried
/// momentum, and there is no such gesture here - a spring that wobbles on
/// something which merely appeared reads as a toy. Everything arrives, settles
/// and stops, a little slower than strictly necessary, which is what reads as
/// calm rather than as quick.
enum Motion {
    /// Panels and sheets.
    static let panel = Animation.spring(duration: 0.42, bounce: 0)
    /// Everything else. Arrives and stops.
    static let ui = Animation.spring(duration: 0.38, bounce: 0)
    /// Press feedback. Short enough to read as instant rather than as motion.
    static let press = Animation.spring(duration: 0.22, bounce: 0)
    /// The stand-in when the system asks for less motion. Still explains the
    /// change; moves nothing across the screen.
    static let gentle = Animation.easeOut(duration: 0.2)
}

extension Animation {
    /// Swaps in the gentle cross-fade when Reduce Motion is on, so call sites
    /// read `Motion.panel.reduced(reduceMotion)` and never have to remember
    /// which animations are safe.
    func reduced(_ reduce: Bool) -> Animation { reduce ? Motion.gentle : self }
}

extension AnyTransition {
    /// How anything that appears should appear: a fade with the faintest
    /// settle. Never a slide, never a scale you can measure.
    static let soft = AnyTransition.opacity.combined(with: .scale(scale: 0.985))
}

// MARK: - Press

/// Every pressable thing acknowledges the touch, on touch *down*.
///
/// The app used `.plain` throughout, which draws no press state at all: a tap
/// produced no acknowledgement until the screen itself changed, which is the
/// moment directness falls off a cliff. Scale is deliberately small - large
/// surfaces need less of it than small ones to read as the same movement.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.98

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
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// Small controls: pills, arrows, text buttons.
    static var pressable: PressableStyle { PressableStyle() }
    /// Full-width rows and cards, where the same ratio reads as a bigger jump.
    static var pressableCard: PressableStyle { PressableStyle(scale: 0.99) }
}

// MARK: - Type

/// Two faces, both of them already on the phone.
///
/// The brief asked for Anthropic's typefaces. Styrene A and Tiempos are both
/// licensed and cannot be bundled, so this is the closest pair iOS ships:
/// **SF Pro** for interface text, which is the neutral grotesque Styrene is,
/// and **New York** for display - a transitional serif with the same high
/// stroke contrast and sturdy bracketed serifs as Tiempos. Nothing to
/// download, nothing to licence, and both carry the full weight range and
/// real optical sizing.
///
/// The rounded face this app used to be set in is gone. Rounded reads friendly
/// and a little unserious; not looking like that was the point of the
/// overhaul.
extension Font {
    /// Fixed size. Only for contexts that need a `Font` value rather than a
    /// view modifier; prefer `View.r(_:_:)`, which scales.
    static func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// The system font at `size`, scaled by the reader's text-size setting.
///
/// `Font.system(size:)` ignores Dynamic Type entirely, so every size in this app
/// used to be a fixed point value - the one accessibility gap left after the
/// contrast work. `@ScaledMetric` is the piece that both scales the number and
/// tells SwiftUI to re-evaluate when the setting changes.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Interface text.
    func r(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: .default))
    }

    /// Display: headlines, and the numbers that are the whole point of a screen.
    ///
    /// New York is rationed deliberately. It earns a screen title and the one
    /// number that screen exists to show - nothing else. Setting small numbers
    /// in it too made the app look like two apps.
    func d(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: .serif))
    }

    /// A paragraph. Anything that wraps to a second line needs the leading
    /// opened up; SwiftUI's default is set for single-line labels and reads as
    /// a wall at four lines.
    func p(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> some View {
        r(size, weight).lineSpacing(size * 0.26)
    }
}

/// New York at a fixed size, for the places UIKit wants a `UIFont`.
enum Display {
    static func uiFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - Sliding selector

/// A row of equal slots with one filled thumb that follows your finger.
///
/// Tapping moves it and dragging carries it, with the selection changing as it
/// passes underneath. Equal slots are what make the second half possible:
/// a thumb that resizes itself per item has no position to interpolate
/// between, so it can only ever cut from one place to the next.
struct SlideBar<T: Hashable, Content: View>: View {
    let items: [T]
    @Binding var selection: T
    var thumb: Color = .ink
    @ViewBuilder let content: (T, Bool) -> Content

    @State private var width: CGFloat = 0
    /// How far the thumb currently sits from its settled slot. Non-zero only
    /// while a finger is on it.
    @State private var carry: CGFloat = 0
    @State private var origin = 0
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var index: Int { items.firstIndex(of: selection) ?? 0 }
    private var slot: CGFloat { items.isEmpty ? 0 : width / CGFloat(items.count) }

    var body: some View {
        // The thumb goes behind the row rather than beside it in a ZStack.
        // A Capsule given only a width fills whatever height it is offered,
        // and inside a ZStack that is the whole screen - which is exactly
        // what it did. As a background it can only be as tall as the row.
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                content(item, item == selection)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.ui.reduced(reduceMotion)) { selection = item }
                    }
            }
        }
        .background(alignment: .leading) {
            if width > 0 {
                Capsule()
                    .fill(thumb)
                    .frame(width: slot)
                    .offset(x: CGFloat(index) * slot + carry)
                    .shadow(color: Color.shade, radius: 7, y: 2)
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        }
        .gesture(drag)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                guard slot > 0 else { return }
                if !dragging {
                    dragging = true
                    origin = index
                }
                let raw = CGFloat(origin) * slot + v.translation.width
                let limit = CGFloat(items.count - 1) * slot
                let x = Swift.min(Swift.max(raw, 0), limit)
                let hit = items[Swift.min(Swift.max(Int((x / slot).rounded()), 0), items.count - 1)]
                if hit != selection {
                    withAnimation(Motion.ui.reduced(reduceMotion)) { selection = hit }
                }
                // Measured from wherever the selection just landed, so the
                // thumb stays under the finger instead of jumping to the slot.
                carry = x - CGFloat(items.firstIndex(of: hit) ?? 0) * slot
            }
            .onEnded { _ in
                dragging = false
                withAnimation(Motion.ui.reduced(reduceMotion)) { carry = 0 }
            }
    }
}

// MARK: - Glass

/// The one background in the app.
///
/// A material, a tint, a lit edge and a shadow - in that order, and all four
/// are load-bearing. Drop the edge and the card has no rim to catch light;
/// drop the shadow and it sits on the ground instead of above it; drop the
/// material and it is a rectangle of paint.
struct GlassBG<S: Shape>: View {
    let shape: S
    var tint: Color = .sur
    var material: Material = .regularMaterial
    var soft: Bool = true

    var body: some View {
        shape
            .fill(material)
            .overlay(shape.fill(tint))
            .overlay(shape.stroke(Color.edge, lineWidth: 0.8))
            .compositingGroup()
            .shadow(color: soft ? Color.shade : .clear, radius: 16, x: 0, y: 7)
    }
}

extension View {
    /// Glass in an arbitrary shape: capsules, circles, chips.
    func glassy<S: Shape>(
        _ shape: S,
        tint: Color = .sur,
        material: Material = .regularMaterial,
        soft: Bool = true
    ) -> some View {
        background(GlassBG(shape: shape, tint: tint, material: material, soft: soft))
    }
}

/// A soft slab of glass. Everything in the app is one of these or a capsule.
struct Slab: ViewModifier {
    var fill: Color = .sur
    var radius: CGFloat = 24
    var padding: EdgeInsets = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassy(RoundedRectangle(cornerRadius: radius, style: .continuous), tint: fill)
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

/// What the glass has to look at.
///
/// A material blurs whatever is behind it, and behind every card here is one
/// flat colour - which blurs to exactly itself. Two very soft monochrome
/// washes give the blur something to find. No hue, nothing that reads as a
/// gradient; just enough tonal variation that the cards separate from the
/// ground and from each other.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color.bg
            GeometryReader { geo in
                let w = geo.size.width
                Circle()
                    .fill(Color.ink.opacity(0.055))
                    .frame(width: w * 1.1)
                    .blur(radius: 90)
                    .offset(x: -w * 0.35, y: -w * 0.30)
                Circle()
                    .fill(Color.ink.opacity(0.04))
                    .frame(width: w * 0.95)
                    .blur(radius: 90)
                    .offset(x: w * 0.45, y: geo.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A card that has not arrived yet.
///
/// Not a spinner: a spinner says "wait" and says nothing about what for. A
/// shape the size of the thing that is coming says both, and the screen does
/// not jump when the real card lands on top of it. The pulse is opacity only
/// - a sweeping highlight is the fashionable version and it draws the eye to
/// the loading state, which is the opposite of the point.
struct Skeleton: View {
    var height: CGFloat = 96
    var radius: CGFloat = 24

    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(height: height)
            .glassy(RoundedRectangle(cornerRadius: radius, style: .continuous), soft: false)
            .opacity(lit ? 1 : 0.55)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    lit = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Charts

/// A trend line with no axes, no labels and no grid.
///
/// The number next to it is the value; this only has to answer "which way".
/// Anything more would be a chart, and a chart is a different screen.
struct Spark: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let lo = values.min() ?? 0
                let hi = values.max() ?? 1
                // A flat series would divide by zero and, worse, render as a
                // dramatic zigzag of rounding noise. Give it a floor.
                let span = Swift.max(hi - lo, 1.0)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * Double(i) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (v - lo) / span)
                        let pt = CGPoint(x: x, y: y)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
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
        .frame(height: 7)
    }
}
