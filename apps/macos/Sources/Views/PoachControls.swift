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

struct PoachSegments<Value: Hashable>: View {
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    var underlined = false
    var symbol: (Value) -> String? = { _ in nil }

    var body: some View {
        if underlined { underlinedBody } else { pillBody }
    }

    /// Text tabs with a short bar under the selected one.
    private var underlinedBody: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.0) { value, title in
                Button {
                    selection = value
                } label: {
                    choiceLabel(value, title)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(PoachPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(alignment: .bottom) {
                            if selection == value {
                                Capsule().fill(PoachPalette.ink)
                                    .frame(width: 22, height: 2)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// A capsule track with a white thumb that slides to the selected choice.
    private var pillBody: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.0) { value, title in
                let selected = selection == value
                Button {
                    selection = value
                } label: {
                    choiceLabel(value, title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? PoachPalette.ink : PoachPalette.ink.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.white)
                                    .overlay { Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 1) }
                                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.18), value: selection)
        .padding(3)
        .background(PoachPalette.inset, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func choiceLabel(_ value: Value, _ title: String) -> some View {
        if let name = symbol(value) {
            // Drop the icon before the title would truncate.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: name).accessibilityHidden(true)
                    Text(title)
                }
                .fixedSize()
                Text(title)
            }
        } else {
            Text(title)
        }
    }
}

struct PoachActionStyle: ButtonStyle {
    var fill = PoachPalette.inset
    var foreground = Color.primary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? foreground : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(enabled ? fill : Color(white: 0.85), in: RoundedRectangle(cornerRadius: 9))
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
