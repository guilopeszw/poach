import SwiftUI

enum PoachPalette {
    static let canvas = Color(red: 247/255, green: 247/255, blue: 245/255)
    static let panel = Color(red: 0.98, green: 0.98, blue: 0.97)
    static let inset = Color(red: 0.93, green: 0.93, blue: 0.92)
    static let ink = Color(red: 41/255, green: 41/255, blue: 39/255)
    static let outline = Color(red: 216/255, green: 216/255, blue: 211/255)
    static let cobalt = Color(red: 32 / 255, green: 37 / 255, blue: 200 / 255)
    static let recordingRed = Color(red: 196 / 255, green: 38 / 255, blue: 46 / 255)
    static let errorText = Color(red: 180/255, green: 35/255, blue: 30/255)
}

/// The three corner radii the app uses. Primary actions and segmented controls are capsules,
/// like the capture pill.
enum PoachRadius {
    /// Thumbnails and small inline fields.
    static let small: CGFloat = 6
    /// Tiles, rows and text fields.
    static let control: CGFloat = 10
    /// Previews and grouped panels.
    static let container: CGFloat = 14
}

extension Shape where Self == RoundedRectangle {
    /// A continuous-corner rectangle, the shape macOS uses for its own controls.
    static func poach(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

struct PoachSegments<Value: Hashable>: View {
    @Namespace private var indicator
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
                        .frame(maxWidth: .infinity, minHeight: underlined ? 22 : 26)
                        .background(alignment: .bottom) {
                            if selection == value && underlined {
                                Capsule().fill(PoachPalette.ink)
                                    .frame(width: 22, height: 2)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            } else if selection == value {
                                Capsule()
                                    .fill(Color.white)
                                    .shadow(color: .black.opacity(0.10), radius: 1.5, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .padding(underlined ? 1 : 2)
        .background(underlined ? Color.clear : PoachPalette.inset, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct PoachActionStyle: ButtonStyle {
    var fill = PoachPalette.inset
    var foreground = Color.primary
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? foreground : Color.secondary)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(enabled ? fill : Color(white: 0.85), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct PoachCountdown: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 56, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .frame(width: 120, height: 120)
            .background(Color(white: 0.22), in: Circle())
            .overlay { Circle().strokeBorder(.red, lineWidth: 4) }
            .accessibilityLabel("Capture starts in \(count) seconds")
    }
}
