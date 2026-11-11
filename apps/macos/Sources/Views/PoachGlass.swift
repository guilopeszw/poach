import AppKit
import SwiftUI

/// Poach's glass surfaces, translated from the `glass-refraction` CSS recipe
/// (github.com/Z1Code/glass-refraction, after Apple's Liquid Glass) into SwiftUI:
/// a behind-window blur, a translucent tint, a specular top edge and overhead glow,
/// faint chromatic dispersion at the edges, a hairline ring and a depth shadow.
/// It follows the system appearance: light glass in light mode, dark glass in dark mode.
enum PoachGlassTier {
    /// Floating chrome such as the capture pill and the main window: densest blur,
    /// slow shimmer sweep, breathing specular highlight, chromatic edges.
    case dense
    /// Content cards and panels: medium blur, top specular line, chromatic edges on hover.
    case card
    /// Small controls and tags: light blur, no animation.
    case pill
}

extension View {
    /// Places a glass surface behind the view. Use a large `cornerRadius` (e.g. 999) for a capsule.
    func poachGlass(_ tier: PoachGlassTier, cornerRadius: CGFloat, hoverable: Bool = false) -> some View {
        modifier(PoachGlassSurface(tier: tier, cornerRadius: cornerRadius, hoverable: hoverable))
    }
}

private struct PoachGlassSurface: ViewModifier {
    let tier: PoachGlassTier
    let cornerRadius: CGFloat
    let hoverable: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var dark: Bool { scheme == .dark }
    private var lifted: Bool { hoverable && hovering }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        PoachPalette.panel
                    } else {
                        PoachGlassBackdrop(cornerRadius: cornerRadius, material: material)
                        tint
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                PoachGlassSheen(
                    cornerRadius: cornerRadius,
                    shimmer: tier == .dense,
                    breathing: tier == .dense,
                    chromatic: tier == .dense || lifted,
                    glow: tier != .pill
                )
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
            .offset(y: lifted ? -2 : 0)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.35), value: lifted)
            .onHover { if hoverable { hovering = $0 } }
    }

    private var material: NSVisualEffectView.Material {
        switch tier {
        case .dense: .hudWindow
        case .card: .popover
        case .pill: .menu
        }
    }

    /// The translucent base (CSS `--gr-bg-start` / `--gr-bg-end`), inverted for light mode.
    private var tint: LinearGradient {
        switch (tier, dark) {
        case (.dense, true):
            LinearGradient(colors: [Color(red: 18/255, green: 22/255, blue: 35/255).opacity(0.48),
                                    Color(red: 12/255, green: 16/255, blue: 28/255).opacity(0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case (.dense, false):
            LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.48)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case (.card, true):
            LinearGradient(colors: [.white.opacity(0.06), Color(red: 15/255, green: 18/255, blue: 30/255).opacity(0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case (.card, false):
            LinearGradient(colors: [.white.opacity(0.72), .white.opacity(0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case (.pill, true):
            LinearGradient(colors: [.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
        case (.pill, false):
            LinearGradient(colors: [.white.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var shadowOpacity: Double {
        if tier == .pill { return 0 }
        let base = dark ? 0.30 : 0.12
        return lifted ? base * 1.5 : base
    }
    /// SwiftUI radii are about half of the CSS blur values (24px dense, 12px / 32px card).
    private var shadowRadius: CGFloat { tier == .dense ? 12 : (lifted ? 16 : 6) }
    private var shadowY: CGFloat { tier == .dense ? 4 : (lifted ? 8 : 2) }
}

/// The light-play layers shared by every glass surface and the timer lens: hairline ring, inner
/// top highlight, overhead glow, specular top line, chromatic edges and the optional shimmer.
struct PoachGlassSheen: View {
    let cornerRadius: CGFloat
    var shimmer = false
    var breathing = false
    var chromatic = true
    var glow = true
    /// Makes the rim brighter, as on the lifted timer lens.
    var strongRim = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var breathe = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            if shimmer && !reduceMotion {
                // A soft diagonal band sweeping across every 7 s.
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(dark ? 0.06 : 0.22), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .rotationEffect(.degrees(15))
                        .offset(x: sweep ? geometry.size.width * 1.2 : -geometry.size.width * 0.7)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: false)) { sweep = true }
                }
            }
            if glow {
                LinearGradient(stops: [.init(color: .white.opacity(dark ? 0.07 : 0.30), location: 0),
                                       .init(color: .clear, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
            }
            if chromatic {
                ZStack {
                    RadialGradient(colors: [Color(red: 0, green: 0.71, blue: 1).opacity(0.045), .clear],
                                   center: UnitPoint(x: 0.12, y: 0.5), startRadius: 0, endRadius: 120)
                    RadialGradient(colors: [Color(red: 0.47, green: 0.31, blue: 1).opacity(0.04), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 120)
                    RadialGradient(colors: [Color(red: 1, green: 0.39, blue: 0.78).opacity(0.035), .clear],
                                   center: UnitPoint(x: 0.88, y: 0.5), startRadius: 0, endRadius: 120)
                    RadialGradient(colors: [Color(red: 0.39, green: 1, blue: 0.71).opacity(0.025), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.88), startRadius: 0, endRadius: 120)
                }
                .opacity(0.8)
                // Each side refracts a different wavelength.
                shape.strokeBorder(LinearGradient(colors: [Color(red: 0, green: 0.71, blue: 1).opacity(0.10),
                                                           Color(red: 1, green: 0.39, blue: 0.78).opacity(0.10)],
                                                  startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                shape.strokeBorder(LinearGradient(colors: [Color(red: 0.39, green: 1, blue: 0.71).opacity(0.07),
                                                           Color(red: 1, green: 0.78, blue: 0.2).opacity(0.07)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            // Specular top line, brightest at the centre.
            GeometryReader { geometry in
                LinearGradient(stops: [.init(color: .clear, location: 0.08),
                                       .init(color: .white.opacity(strongRim ? 0.9 : 0.55), location: 0.5),
                                       .init(color: .clear, location: 0.92)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width, height: 1)
                    .opacity(breathing && !reduceMotion ? (breathe ? 1 : 0.6) : 1)
            }
            .onAppear {
                guard breathing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { breathe = true }
            }
            // Hairline ring plus an inner highlight along the top.
            shape.strokeBorder(dark ? Color.white.opacity(strongRim ? 0.35 : 0.10) : Color.black.opacity(strongRim ? 0.16 : 0.08),
                               lineWidth: 0.5)
            shape.inset(by: 0.5).strokeBorder(
                LinearGradient(colors: [.white.opacity(dark ? 0.12 : 0.7), .clear], startPoint: .top, endPoint: .center),
                lineWidth: strongRim ? 1.5 : 1
            )
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fills for controls that sit on glass: neutral wells and the selected chip.
enum PoachGlassFill {
    static func control(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    static func selected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.20) : .white.opacity(0.92)
    }
}

/// A behind-window blur (CSS `backdrop-filter`), masked to a rounded shape so it also works
/// in transparent overlay panels.
struct PoachGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> RoundedEffectView {
        let view = RoundedEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: RoundedEffectView, context: Context) {
        view.material = material
        view.cornerRadius = cornerRadius
    }
}

final class RoundedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    override func layout() {
        super.layout()
        let radius = max(0, min(cornerRadius, bounds.width / 2, bounds.height / 2))
        maskImage = radius > 0 ? Self.mask(radius: radius) : nil
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
