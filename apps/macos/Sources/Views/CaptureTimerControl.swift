import SwiftUI

/// Camera-style timer control: a round icon that expands into Off · 3s · 10s.
struct PoachCaptureTimerControl: View {
    enum Style { case light, dark }

    @AppStorage(PoachCaptureTimer.storageKey) private var storedSeconds = PoachCaptureTimer.off.rawValue
    @Binding var isExpanded: Bool
    var style: Style = .light
    /// Opens the options to the left of the icon, for controls pinned to a right edge.
    var expandsLeading = false
    @FocusState private var optionsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var timer: PoachCaptureTimer { PoachCaptureTimer(storedSeconds: storedSeconds) }
    private static let activeTint = Color(red: 0.77, green: 0.42, blue: 0)
    private static let activeFill = Color(red: 0.99, green: 0.90, blue: 0.78)

    var body: some View {
        HStack(spacing: 6) {
            if expandsLeading, isExpanded {
                options.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            }
            toggle
            if !expandsLeading, isExpanded {
                options.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.12), value: isExpanded)
    }

    private var toggle: some View {
        Button {
            setExpanded(!isExpanded)
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(timer == .off ? idleTint : Self.activeTint)
                .frame(width: 32, height: 32)
                .background(timer == .off ? idleFill : Self.activeFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timer")
        .accessibilityValue(timer.spokenTitle)
        .accessibilityHint(isExpanded ? "Hides timer options" : "Shows timer options")
        .help("Recording timer: \(timer.spokenTitle)")
    }

    private var options: some View {
        HStack(spacing: 2) {
            ForEach(PoachCaptureTimer.allCases) { option in
                Button {
                    storedSeconds = option.rawValue
                    setExpanded(false)
                } label: {
                    Text(option.shortTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(option == timer ? Self.activeTint : optionTint)
                        .frame(minWidth: 34, minHeight: 26)
                        .padding(.horizontal, 4)
                        .background(option == timer ? selectedFill : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.spokenTitle)
                .accessibilityAddTraits(option == timer ? .isSelected : [])
            }
        }
        .padding(3)
        .background(idleFill, in: Capsule())
        .focusable()
        .focused($optionsFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.return) { setExpanded(false); return .handled }
        .onKeyPress(.escape) { setExpanded(false); return .handled }
        .onAppear { optionsFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer options")
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        storedSeconds = timer.stepped(by: delta).rawValue
        return .handled
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    private var idleTint: Color { style == .light ? PoachPalette.ink : .white }
    private var optionTint: Color { style == .light ? Color(white: 0.35) : Color(white: 0.88) }
    private var idleFill: Color { style == .light ? Color(white: 0.93) : .white.opacity(0.18) }
    private var selectedFill: Color { style == .light ? .white : .white.opacity(0.95) }
}
