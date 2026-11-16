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
    /// Room around the pill in its own panels, so the press lens and the shadow are not clipped.
    static let panelMargin: CGFloat = 16

    /// Bottom corner of `screen`, on the side chosen in Settings (`windowEdge`).
    @MainActor
    static func frame(on screen: NSScreen) -> CGRect {
        let left = UserDefaults.standard.string(forKey: "windowEdge") == "left"
        let x = left ? screen.frame.minX + sideInset : screen.frame.maxX - size.width - sideInset
        return CGRect(x: x, y: screen.frame.minY + bottomInset, width: size.width, height: size.height)
    }

    /// `frame(on:)` grown by `panelMargin`; the pill stays centred in it.
    @MainActor
    static func panelFrame(on screen: NSScreen) -> CGRect {
        frame(on: screen).insetBy(dx: -panelMargin, dy: -panelMargin)
    }

    /// The pill attached to a selected area (AppKit global coordinates) on `screen`,
    /// matching where the selection overlay showed it. See `CaptureTargetGeometry.attachedPillFrame`.
    @MainActor
    static func frame(attachedTo area: CGRect, on screen: NSScreen) -> CGRect {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        // To the screen's top-left space and back.
        let local = CGRect(x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY,
                           width: area.width, height: area.height)
        let pill = CaptureTargetGeometry.attachedPillFrame(for: local, pillSize: size, in: bounds)
        return CGRect(x: screen.frame.minX + pill.minX, y: screen.frame.maxY - pill.maxY,
                      width: pill.width, height: pill.height)
    }

    @MainActor
    static func panelFrame(attachedTo area: CGRect, on screen: NSScreen) -> CGRect {
        frame(attachedTo: area, on: screen).insetBy(dx: -panelMargin, dy: -panelMargin)
    }

    static var panelSize: CGSize {
        CGSize(width: size.width + panelMargin * 2, height: size.height + panelMargin * 2)
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
    /// Pointer x over the button row while pressed; `nil` when no lens is shown.
    @State private var lensX: CGFloat?

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
        .background { CapturePillGlass() }
        .overlay { progressEdge }
        .background { shortcuts }
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.1), value: timerExpanded)
        .preferredColorScheme(.light)
    }

    private var buttons: some View {
        HStack(spacing: CapturePillLens.spacing) {
            Button { timerExpanded = true } label: {
                CaptureTimerGlyph(timer: timer)
                    .foregroundStyle(timer == .off ? PoachPalette.ink : Self.activeTint)
                    .frame(width: 44, height: 32)
                    .background(timer == .off ? Color.clear : Self.activeFill, in: Capsule())
                    .scaleEffect(magnification(for: 0))
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
                    .scaleEffect(magnification(for: 1))
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
                    .scaleEffect(magnification(for: 2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!cancelEnabled)
            .opacity(cancelEnabled ? 1 : Self.dimmed)
            .keyboardShortcut(cancelEnabled ? .cancelAction : nil)
            .accessibilityLabel(phase == .countdown ? "Cancel countdown" : "Cancel selection")
            .help(phase == .countdown ? "Cancel countdown (Esc)" : "Cancel (Esc)")
        }
        .overlay { lensLayer }
    }

    // MARK: Press lens

    /// The button under the lens grows a little, as if seen through it.
    private func magnification(for slot: Int) -> CGFloat {
        lensX.map { CapturePillLens.slot(atX: $0) == slot } == true && !reduceMotion ? 1.16 : 1
    }

    private func isEnabled(slot: Int) -> Bool {
        switch slot {
        case 0: isSelecting
        case 1: primaryEnabled
        default: cancelEnabled
        }
    }

    private func perform(slot: Int) {
        guard isEnabled(slot: slot) else { return }
        switch slot {
        case 0: timerExpanded = true
        case 1: onPrimary()
        default: onCancel()
        }
    }

    /// Pressing anywhere on the row lifts a glass lens that follows the pointer, after the
    /// iOS 26 tab bar. Releasing over an enabled button triggers it. The real buttons stay
    /// underneath for keyboard shortcuts and accessibility.
    private var lensLayer: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                if let lensX {
                    CapturePillLensShape()
                        .frame(width: CapturePillLens.size.width, height: CapturePillLens.size.height)
                        .position(x: min(max(lensX, CapturePillLens.size.width / 2 - 6),
                                         width - CapturePillLens.size.width / 2 + 6),
                                  y: geometry.size.height / 2)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                            lensX = value.location.x
                        }
                    }
                    .onEnded { value in
                        let inside = value.location.y > -12 && value.location.y < geometry.size.height + 12
                        let slot = CapturePillLens.slot(atX: value.location.x)
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72)) {
                            lensX = nil
                        }
                        if inside { perform(slot: slot) }
                    }
            )
        }
        .accessibilityHidden(true)
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

/// Geometry of the press lens over the three 44 pt buttons.
enum CapturePillLens {
    static let spacing: CGFloat = 8
    /// Wider than a button and taller than the pill, so it overflows like the iOS lens.
    static let size = CGSize(width: 62, height: 58)

    /// 0 = ⏱, 1 = ● / 📷 / ■, 2 = ✕; positions past either end clamp.
    static func slot(atX x: CGFloat) -> Int {
        min(max(Int(((x + spacing / 2) / (44 + spacing)).rounded(.down)), 0), 2)
    }
}

/// A clear lens: a faint white body, a bright rim that fades downward and a soft shadow.
private struct CapturePillLensShape: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35), .black.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.2
                )
            }
            .overlay {
                // A thin inner glint near the top edge.
                Capsule()
                    .inset(by: 3)
                    .trim(from: 0.55, to: 0.95)
                    .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
    }
}

/// The pill's glass: a light behind-window blur, a white wash, a rim that is bright on top and
/// a soft shadow. Inside a regular window (the window chooser), it blurs that window's content.
struct CapturePillGlass: View {
    @Environment(\.capturePillBlending) private var blending

    var body: some View {
        CapturePillBlur(blending: blending)
            .clipShape(Capsule())
            .overlay { Capsule().fill(Color.white.opacity(0.38)) }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            }
            .overlay { Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
            .allowsHitTesting(false)
    }
}

private struct CapturePillBlur: NSViewRepresentable {
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blending
    }
}

private struct CapturePillBlendingKey: EnvironmentKey {
    static let defaultValue = NSVisualEffectView.BlendingMode.behindWindow
}

extension EnvironmentValues {
    /// `.behindWindow` for the pill's own panels and overlays; `.withinWindow` inside a regular window.
    var capturePillBlending: NSVisualEffectView.BlendingMode {
        get { self[CapturePillBlendingKey.self] }
        set { self[CapturePillBlendingKey.self] = newValue }
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
                // Same face as the Off · 3s · 10s options.
                Text("\(timer.seconds)")
                    .font(.system(size: timer.seconds >= 10 ? 8.5 : 10, weight: .bold))
            }
            .frame(width: 20, height: 22)
            // Centre the whole stopwatch, crown included, in the button.
            .offset(y: 1)
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
