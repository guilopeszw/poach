import AppKit
import SwiftUI

/// Where the capture flow is; it decides which pill buttons are active.
enum CapturePillPhase: Equatable {
    /// Choosing a target. `canStart` enables ● / 📷.
    case selecting(canStart: Bool)
    /// The optional countdown is running. Only ✕ (cancel) is active.
    case countdown
    /// Recording. Only ■ (stop) is active; the pill edge fills with the elapsed time.
    case recording(elapsed: Int, limit: Int)
}

/// Layout shared by every window that shows the pill, so it never jumps between phases.
enum CapturePillLayout {
    static let size = CGSize(width: 168, height: 48)
    static let bottomInset: CGFloat = 26
    static let sideInset: CGFloat = 18

    /// Bottom corner of `screen`, on the side chosen in Settings (`windowEdge`).
    @MainActor
    static func frame(on screen: NSScreen) -> CGRect {
        let left = UserDefaults.standard.string(forKey: "windowEdge") == "left"
        let x = left ? screen.frame.minX + sideInset : screen.frame.maxX - size.width - sideInset
        return CGRect(x: x, y: screen.frame.minY + bottomInset, width: size.width, height: size.height)
    }
}

/// The floating capture pill: ⏱ · ● · ✕ (⏱ · 📷 · ✕ for screenshots).
/// Clicking ⏱ expands the timer options over the whole pill; choosing one collapses it.
struct CapturePill: View {
    let phase: CapturePillPhase
    var screenshot = false
    @Binding var timerExpanded: Bool
    let onPrimary: () -> Void
    let onCancel: () -> Void

    @AppStorage(PoachCaptureTimer.storageKey) private var storedSeconds = PoachCaptureTimer.off.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var optionsFocused: Bool

    private static let activeTint = Color(red: 0.77, green: 0.42, blue: 0)
    private static let activeFill = Color(red: 0.99, green: 0.90, blue: 0.78)
    private static let dimmed = 0.35

    private var timer: PoachCaptureTimer { PoachCaptureTimer(storedSeconds: storedSeconds) }
    private var isSelecting: Bool { if case .selecting = phase { true } else { false } }
    private var isRecording: Bool { if case .recording = phase { true } else { false } }
    private var primaryEnabled: Bool {
        switch phase {
        case .selecting(let canStart): canStart
        case .countdown: false
        case .recording: true
        }
    }
    private var cancelEnabled: Bool { !isRecording }

    var body: some View {
        ZStack {
            if timerExpanded && isSelecting {
                options
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.2, anchor: .leading).combined(with: .opacity),
                        // Closing slides the options back into the ⏱ button.
                        removal: .modifier(active: TimerOptionsCollapse(progress: 1),
                                           identity: TimerOptionsCollapse(progress: 0))
                    ))
            } else {
                buttons
                    .transition(.opacity)
            }
        }
        .frame(width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
        .background(Color.white, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.black.opacity(0.15), lineWidth: 1).allowsHitTesting(false)
        }
        .overlay { progressEdge }
        .background { shortcuts }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.1), value: timerExpanded)
        .preferredColorScheme(.light)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { timerExpanded = true } label: {
                CaptureTimerGlyph(timer: timer)
                    .foregroundStyle(timer == .off ? PoachPalette.ink : Self.activeTint)
                    .frame(width: 44, height: 32)
                    .background(timer == .off ? Color(white: 0.93) : Self.activeFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isSelecting)
            .opacity(isSelecting ? 1 : Self.dimmed)
            .accessibilityLabel("Timer")
            .accessibilityValue(timer.spokenTitle)
            .accessibilityHint("Shows timer options")
            .help("Capture timer: \(timer.spokenTitle) (T)")

            Button(action: onPrimary) {
                Image(systemName: primarySymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .frame(width: 44, height: 32)
                    .background(primaryBackground, in: Capsule())
                    // The white record button needs an edge to stand apart from the white pill.
                    .overlay {
                        if primaryBackground == .white {
                            Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(primaryBackground == .white ? 0.12 : 0), radius: 3, x: 0, y: 1)
                    .contentShape(Capsule())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .opacity(primaryEnabled ? 1 : Self.dimmed)
            .accessibilityLabel(primaryLabel)
            .accessibilityValue(recordingValue ?? "")
            .help(primaryHelp)
            .keyboardShortcut(.defaultAction)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PoachPalette.ink)
                    .frame(width: 44, height: 32)
                    .background(Color(white: 0.93), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!cancelEnabled)
            .opacity(cancelEnabled ? 1 : Self.dimmed)
            .keyboardShortcut(cancelEnabled ? .cancelAction : nil)
            .accessibilityLabel(phase == .countdown ? "Cancel countdown" : "Cancel selection")
            .help(phase == .countdown ? "Cancel countdown (Esc)" : "Cancel (Esc)")
        }
    }

    /// Off · 3s · 10s, covering the whole pill. A lens marks the choice: press or drag to
    /// slide it across the options, release to settle and close the timer.
    private var options: some View {
        CaptureTimerLensPicker(
            selection: Binding(get: { timer }, set: { storedSeconds = $0.rawValue }),
            tint: Self.activeTint,
            fill: Self.activeFill,
            onCommit: { timerExpanded = false }
        )
        .padding(.horizontal, 8)
        .focusable()
        .focused($optionsFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { storedSeconds = timer.stepped(by: -1).rawValue; return .handled }
        .onKeyPress(.rightArrow) { storedSeconds = timer.stepped(by: 1).rawValue; return .handled }
        .onKeyPress(.return) { timerExpanded = false; return .handled }
        .onAppear { optionsFocused = true }
    }

    /// While recording, a red line fills the pill's edge over the clip limit.
    @ViewBuilder private var progressEdge: some View {
        if case .recording(let elapsed, let limit) = phase, limit > 0 {
            Capsule()
                .trim(from: 0, to: min(1, CGFloat(elapsed) / CGFloat(limit)))
                .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(1)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: elapsed)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Space acts like the primary button and T opens the timer; both only while the pill's window is key.
    private var shortcuts: some View {
        Group {
            Button("", action: onPrimary)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!primaryEnabled || timerExpanded)
            Button("") { if isSelecting { timerExpanded.toggle() } }
                .keyboardShortcut("t", modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var primarySymbol: String {
        if isRecording { return "stop.fill" }
        return screenshot ? "camera" : "circle.fill"
    }

    /// Record: white with a red circle. Stop: red with a white square. Screenshot: ink with a white camera.
    private var primaryBackground: Color {
        if isRecording { return .red }
        return screenshot ? PoachPalette.ink : .white
    }

    private var primaryForeground: Color {
        isRecording || screenshot ? .white : .red
    }

    private var primaryLabel: String {
        if isRecording { return "Stop recording" }
        return screenshot ? "Take screenshot" : "Start recording"
    }

    private var recordingValue: String? {
        guard case .recording(let elapsed, let limit) = phase else { return nil }
        return "\(elapsed) of \(limit) seconds"
    }

    private var primaryHelp: String {
        switch (phase, screenshot, timer) {
        case (.recording(let elapsed, let limit), _, _):
            return "Stop (Space or Return) · \(clock(elapsed)) / \(clock(limit))"
        case (_, true, .off): return "Take screenshot (Return)"
        case (_, true, _): return "Take a screenshot after \(timer.spokenTitle) (Return)"
        case (_, false, .off): return "Start recording (Return)"
        case (_, false, _): return "Start the \(timer.spokenTitle) countdown (Return)"
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Where the ⏱ button sits inside the pill: the first of three 44 × 32 buttons, 8 pt apart, centred.
private enum CapturePillTimerButton {
    static let size = CGSize(width: 44, height: 32)
    static var origin: CGPoint {
        let row = size.width * 3 + 8 * 2
        return CGPoint(x: (CapturePillLayout.size.width - row) / 2, y: (CapturePillLayout.size.height - size.height) / 2)
    }
}

/// ⏱ when the timer is off; with 3s or 10s chosen, the seconds sit inside a stopwatch outline.
private struct CaptureTimerGlyph: View {
    let timer: PoachCaptureTimer

    var body: some View {
        if timer == .off {
            Image(systemName: "timer")
                .font(.system(size: 15, weight: .semibold))
        } else {
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: 1.6)
                    .frame(width: 18, height: 18)
                Capsule()
                    .frame(width: 5, height: 2.2)
                    .offset(y: -10.4)
                Text("\(timer.seconds)")
                    .font(.system(size: timer.seconds >= 10 ? 8.5 : 9.5, weight: .bold, design: .rounded).monospacedDigit())
                    .offset(y: 0.5)
            }
            .frame(width: 20, height: 22)
            .accessibilityHidden(true)
        }
    }
}

/// Closing the timer options: the pill-wide options shrink into the ⏱ button's capsule
/// while their labels slide left and fade, so they read as tucking back into the button.
private struct TimerOptionsCollapse: Animatable {
    /// 0 shows the full options; 1 has them folded into the ⏱ button.
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
}

extension TimerOptionsCollapse: ViewModifier {
    func body(content: Content) -> some View {
        let full = CapturePillLayout.size
        let button = CapturePillTimerButton.size
        let origin = CapturePillTimerButton.origin
        content
            .offset(x: -progress * (full.width / 2 - origin.x - button.width / 2))
            .opacity(Double(1 - progress))
            .mask(alignment: .topLeading) {
                Capsule()
                    .frame(width: full.width + (button.width - full.width) * progress,
                           height: full.height + (button.height - full.height) * progress)
                    .offset(x: origin.x * progress, y: origin.y * progress)
            }
    }
}

/// The timer options with a sliding lens, after iOS's glass tab bar: the chosen option sits on a
/// filled capsule; while pressed, the capsule lifts into a larger white lens that follows the
/// pointer (and overflows the pill), and the option under it becomes the choice. On release it
/// settles back onto the option with a spring.
private struct CaptureTimerLensPicker: View {
    @Binding var selection: PoachCaptureTimer
    let tint: Color
    let fill: Color
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pointer x while pressed; `nil` when the lens rests on `selection`.
    @State private var dragX: CGFloat?

    private static let restingHeight: CGFloat = 32
    private static let liftedHeight: CGFloat = 58
    private static let liftedExtraWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let count = CGFloat(PoachCaptureTimer.allCases.count)
            let segment = width / count
            let lifted = dragX != nil
            let lensWidth = segment + (lifted ? Self.liftedExtraWidth : 0)
            // While pressed the lens follows the pointer; at rest it centres on the choice.
            let centre = dragX.map { min(max($0, lensWidth / 2), width - lensWidth / 2) }
                ?? segment * (CGFloat(selection.index) + 0.5)

            ZStack(alignment: .topLeading) {
                lens(lifted: lifted)
                    .frame(width: lensWidth, height: lifted ? Self.liftedHeight : Self.restingHeight)
                    .position(x: centre, y: geometry.size.height / 2)

                HStack(spacing: 0) {
                    ForEach(PoachCaptureTimer.allCases) { option in
                        Text(option.shortTitle)
                            .font(.system(size: 13, weight: option == selection ? .bold : .semibold))
                            .foregroundStyle(option == selection ? tint : Color(white: 0.4))
                            .scaleEffect(lifted && option == selection && !reduceMotion ? 1.18 : 1)
                            .frame(width: segment, height: geometry.size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let x = value.location.x
                        let option = PoachCaptureTimer.option(atX: Double(x), trackWidth: Double(width))
                        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                            dragX = x
                            selection = option
                        }
                    }
                    .onEnded { value in
                        let option = PoachCaptureTimer.option(atX: Double(value.location.x), trackWidth: Double(width))
                        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.68)) {
                            selection = option
                            dragX = nil
                        }
                        // Let the lens settle before the pill folds back.
                        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.32)) { onCommit() }
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer")
        .accessibilityValue(selection.spokenTitle)
        .accessibilityHint("Swipe up or down to change, then press Return")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = selection.stepped(by: 1)
            case .decrement: selection = selection.stepped(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction { onCommit() }
    }

    /// Resting: a filled capsule. Lifted: a white lens with a bright rim and a soft shadow.
    @ViewBuilder private func lens(lifted: Bool) -> some View {
        if lifted {
            Capsule()
                .fill(Color.white)
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white, .black.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.5
                    )
                }
                .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 5)
        } else {
            Capsule().fill(fill)
        }
    }
}
