import AppKit
import SwiftUI

enum PoachPalette {
    // Neutral colors follow the system appearance. Windows that force light mode
    // (editor, onboarding) keep resolving to the light values.
    static let canvas = dynamic(light: (247, 247, 245), dark: (30, 30, 32))
    static let panel = dynamic(light: (250, 250, 247), dark: (44, 44, 46))
    static let inset = dynamic(light: (237, 237, 235), dark: (58, 58, 60))
    static let ink = dynamic(light: (41, 41, 39), dark: (236, 236, 232))
    static let outline = dynamic(light: (216, 216, 211), dark: (80, 80, 84))
    /// Charcoal that stays dark in both appearances, for fills behind white text and icons.
    static let solidInk = Color(red: 41/255, green: 41/255, blue: 39/255)
    static let cobalt = Color(red: 32 / 255, green: 37 / 255, blue: 200 / 255)
    static let recordingRed = Color(red: 196 / 255, green: 38 / 255, blue: 46 / 255)
    static let errorText = dynamic(light: (180, 35, 30), dark: (255, 105, 97))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        })
    }
}

struct PoachSegments<Value: Hashable>: View {
    @Namespace private var indicator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    var underlined = false
    var symbol: (Value) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.0) { value, title in
                Button {
                    selection = value
                } label: {
                    Group {
                        if let name = symbol(value) {
                            Label(title, systemImage: name)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Text(title)
                        }
                    }
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(PoachPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(alignment: .bottom) {
                            if selection == value && underlined {
                                Capsule().fill(PoachPalette.ink)
                                    .frame(width: 22, height: 2)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            } else if selection == value {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(PoachGlassFill.selected(scheme))
                                    .overlay { PoachGlassSheen(cornerRadius: 5, chromatic: false, glow: false) }
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 2, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .padding(1)
        .background(underlined ? Color.clear : PoachGlassFill.control(scheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct PoachActionStyle: ButtonStyle {
    /// `nil` uses the neutral glass well; colored fills get a glossy top edge.
    var fill: Color? = nil
    var foreground = Color.primary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? foreground : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if enabled, fill != nil {
                    PoachGlassSheen(cornerRadius: 9, chromatic: false)
                }
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
    }

    private var background: Color {
        guard enabled else { return PoachGlassFill.control(scheme) }
        return fill ?? PoachGlassFill.control(scheme)
    }
}

struct PoachCountdown: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 56, weight: .semibold).monospacedDigit())
            .foregroundStyle(PoachPalette.ink)
            .contentTransition(.numericText())
            .frame(width: 120, height: 120)
            .poachGlass(.dense, cornerRadius: 60)
            .overlay { Circle().strokeBorder(.red, lineWidth: 4) }
            .accessibilityLabel("Capture starts in \(count) seconds")
    }
}
