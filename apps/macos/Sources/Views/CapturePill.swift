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
    /// Room around the pill in its own panels, so the timer lens and the shadow are not clipped.
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
    /// Fades the buttons without the glass, for the drop-in animation.
    var controlsOpacity: Double = 1

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
        .opacity(controlsOpacity)
        .allowsHitTesting(controlsOpacity > 0.5)
        .frame(width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
        .background { CapturePillGlass() }
        .overlay { progressEdge }
        .background { shortcuts }
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.1), value: timerExpanded)
        .preferredColorScheme(.light)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { timerExpanded = true } label: {
                CaptureTimerGlyph(timer: timer)
                    .foregroundStyle(timer == .off ? PoachPalette.ink : Self.activeTint)
                    .frame(width: 44, height: 32)
                    .background(timer == .off ? Color.clear : Self.activeFill, in: Capsule())
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

/// The area pill's entrance, like a drop of liquid leaving the selection outline:
/// 1. the outline swells at `origin` into a drop held by a neck that stretches and snaps
///    (a metaball: blurred shapes cut at half opacity);
/// 2. the free drop falls to the pill's centre;
/// 3. it grows into the pill, its white becoming the pill's rim while the glass shows through;
/// 4. the buttons fade in.
/// With Reduce Motion the pill simply appears.
struct CapturePillDropIn<Pill: View>: View {
    /// Where the drop leaves the outline, in the parent's coordinates.
    let origin: CGPoint
    /// The pill's final frame, in the parent's coordinates.
    let frame: CGRect
    let pill: (Double) -> Pill

    @State private var start = Date()
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var pinch: Double { 0.46 }
    private static var fall: Double { 0.22 }
    private static var grow: Double { 0.6 }
    private static var fade: Double { 0.2 }
    private static var total: Double { pinch + fall + grow + fade }
    private static var dropRadius: CGFloat { 8 }
    private static var pinchDepth: CGFloat { 20 }

    var body: some View {
        if reduceMotion {
            pill(1).position(x: frame.midX, y: frame.midY)
        } else {
            TimelineView(.animation(paused: finished)) { timeline in
                content(at: timeline.date.timeIntervalSince(start))
            }
            .task {
                try? await Task.sleep(for: .seconds(Self.total + 0.05))
                finished = true
            }
        }
    }

    @ViewBuilder
    private func content(at t: Double) -> some View {
        let direction: CGFloat = frame.midY >= origin.y ? 1 : -1
        let pinched = CGPoint(x: origin.x, y: origin.y + direction * Self.pinchDepth)
        let growStart = Self.pinch + Self.fall
        ZStack(alignment: .topLeading) {
            if t < Self.pinch {
                // The outline swells into a drop on a stretching neck.
                let p = Self.easeInOut(t / Self.pinch)
                let centre = CGPoint(x: origin.x, y: origin.y + direction * Self.pinchDepth * p)
                // Wide and flat at first, rounder as it hangs lower.
                goo(drop: centre, radius: 3 + (Self.dropRadius - 3) * p, stretch: 1.9 - 0.9 * p, direction: direction)
            } else if t < growStart {
                // The free drop falls, stretching along its path as it speeds up.
                let f = Self.easeIn((t - Self.pinch) / Self.fall)
                let centre = CGPoint(x: frame.midX, y: pinched.y + (frame.midY - pinched.y) * f)
                Ellipse()
                    .fill(Color.white)
                    .frame(width: Self.dropRadius * 2 * (1 - 0.18 * f), height: Self.dropRadius * 2 * (1 + 0.4 * f))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .position(centre)
            } else {
                // On landing it squashes, then spreads sideways like liquid while its height
                // catches up a moment later; both settle with a gentle wobble.
                let x = (t - growStart) / Self.grow
                let drop = Self.dropRadius * 2
                let spread = Self.spring(x, damping: 6.5, frequency: 6.5)
                let rise = Self.spring((x - 0.12) / 0.88, damping: 7, frequency: 6.5)
                let squash = drop * (1 - 0.35 * Self.bump(x / 0.18))
                let width = max(drop * 0.8, drop + (frame.width - drop) * spread)
                let height = max(4, rise <= 0 ? squash : squash + (frame.height - squash) * rise)
                let g = min(max(x / 0.6, 0), 1)
                let controls = min(max((t - growStart - Self.grow * 0.55) / Self.fade, 0), 1)
                pill(controls)
                    .mask { Capsule().frame(width: width, height: height) }
                    .position(x: frame.midX, y: frame.midY)
                Capsule()
                    .fill(Color.white.opacity(Double(max(0, 1 - g * 1.3))))
                    .overlay { Capsule().strokeBorder(.white, lineWidth: 2).opacity(Double(max(0, 1 - g))) }
                    .frame(width: width, height: height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The outline segment and the drop, blurred and cut at half opacity so they melt together.
    /// Only the side of the outline facing the pill is drawn; the outline itself stays crisp.
    private func goo(drop centre: CGPoint, radius: CGFloat, stretch: CGFloat, direction: CGFloat) -> some View {
        Canvas { context, size in
            let side = direction > 0
                ? CGRect(x: 0, y: origin.y, width: size.width, height: max(0, size.height - origin.y))
                : CGRect(x: 0, y: 0, width: size.width, height: max(0, origin.y))
            context.clip(to: Path(side))
            context.addFilter(.alphaThreshold(min: 0.5, color: .white))
            context.addFilter(.blur(radius: 4))
            context.drawLayer { layer in
                layer.fill(Path(CGRect(x: origin.x - 34, y: origin.y - 2, width: 68, height: 4)), with: .color(.white))
                layer.fill(Path(ellipseIn: CGRect(x: centre.x - radius * stretch, y: centre.y - radius,
                                                  width: radius * 2 * stretch, height: radius * 2)), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }

    private static func easeInOut(_ x: Double) -> CGFloat {
        let x = min(max(x, 0), 1)
        return CGFloat(x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2)
    }

    private static func easeIn(_ x: Double) -> CGFloat {
        let x = min(max(x, 0), 1)
        return CGFloat(x * x)
    }

    /// A damped spring from 0 to 1 over `x` in 0...1: a little overshoot and wobble, settled at 1.
    private static func spring(_ x: Double, damping: Double, frequency: Double) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Fade the residual so the curve lands exactly on 1 at the end.
        let residual = exp(-damping * x) * cos(frequency * x) * (1 - x * x * x)
        return CGFloat(1 - residual)
    }

    /// Rises to 1 at the middle of 0...1 and falls back to 0: the landing squash.
    private static func bump(_ x: Double) -> CGFloat {
        guard x > 0, x < 1 else { return 0 }
        return CGFloat(sin(x * .pi))
    }
}

/// The pill's glass. On macOS 26 it is the system's Liquid Glass, which refracts and tints
/// what is behind the pill (the desktop for the pill's own panels, the window content inside
/// the window chooser). Earlier systems keep `CapturePillLegacyGlass`.
struct CapturePillGlass: View {
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Light glass even in Dark Mode or over dark windows, so the dark icons stay legible.
                Color.clear.glassEffect(.regular, in: Capsule())
                    .environment(\.colorScheme, .light)
            } else {
                CapturePillLegacyGlass()
            }
        }
        .allowsHitTesting(false)
    }
}

/// macOS 14 and 15: a light behind-window blur and a white wash, edged like real glass instead
/// of with an outline. A specular highlight catches the top edge and fades away (reflection), and
/// a faint spectral fringe runs around the rim, slightly blurred (diffraction). Inside a regular
/// window (the window chooser), the blur uses that window's content.
private struct CapturePillLegacyGlass: View {
    @Environment(\.capturePillBlending) private var blending

    var body: some View {
        // Kept thin so what is behind the pill shows through clearly.
        CapturePillBlur(blending: blending)
            .opacity(0.7)
            .clipShape(Capsule())
            .overlay { Capsule().fill(Color.white.opacity(0.12)) }
            .overlay { CapturePillGlassEdge() }
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
    }
}

private struct CapturePillGlassEdge: View {
    var body: some View {
        ZStack {
            // Diffraction: a thin rainbow fringe, strongest at the ends, softened so it reads as light.
            Capsule()
                .strokeBorder(
                    AngularGradient(colors: [
                        .cyan.opacity(0.55), .blue.opacity(0.35), .purple.opacity(0.45), .pink.opacity(0.4),
                        .orange.opacity(0.35), .yellow.opacity(0.4), .green.opacity(0.3), .cyan.opacity(0.55)
                    ], center: .center),
                    lineWidth: 1.5
                )
                .blur(radius: 0.8)
                .blendMode(.plusLighter)
            // Reflection: a bright highlight along the top edge that fades out down the sides.
            Capsule()
                .strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.95), location: 0),
                        .init(color: .white.opacity(0.35), location: 0.35),
                        .init(color: .white.opacity(0), location: 0.6)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            // A soft inner glint below the top edge.
            Capsule()
                .inset(by: 2.5)
                .trim(from: 0.6, to: 0.9)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .blur(radius: 0.6)
        }
        .clipShape(Capsule())
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
                if progress > 0 {
                    Capsule()
                        .frame(width: full.width + (button.width - full.width) * progress,
                               height: full.height + (button.height - full.height) * progress)
                        .offset(x: origin.x * progress, y: origin.y * progress)
                } else {
                    // Open: no clipping, so the lifted lens can overhang the pill.
                    Rectangle().padding(-CapturePillLayout.panelMargin)
                }
            }
    }
}

/// The timer options as a glass segmented control (Poach brief `FDBFE307…`): the chosen option
/// sits on a soft white thumb; while pressed, the thumb lifts into a larger, almost clear lens
/// that follows the pointer (and overflows the pill), and the option under it becomes the choice
/// at once. On release the lens settles back into the thumb with a spring. On macOS 26 the
/// lifted lens is clear Liquid Glass under the labels; earlier systems fake the refraction.
/// A mask that keeps either the inside of a capsule-shaped lens or everything outside it.
private struct LensCutout: View {
    let lens: CGRect
    let inside: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path(roundedRect: lens, cornerRadius: lens.height / 2, style: .continuous)
            if inside {
                context.fill(path, with: .color(.black))
            } else {
                path.addRect(CGRect(origin: .zero, size: size))
                context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
            }
        }
    }
}

private struct CaptureTimerLensPicker: View {
    @Binding var selection: PoachCaptureTimer
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pointer x while pressed; `nil` when the lens rests on `selection`.
    @State private var dragX: CGFloat?

    private static var hasLiquidGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    private static let restingHeight: CGFloat = 32
    /// The lifted lens is taller than the 48 pt pill so it overlaps the pill's edges.
    private static let liftedHeight: CGFloat = 64
    private static let liftedExtraWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let count = CGFloat(PoachCaptureTimer.allCases.count)
            let segment = width / count
            let lifted = dragX != nil
            let lensWidth = segment + (lifted ? Self.liftedExtraWidth : 0)
            // While pressed the lens follows the pointer; at rest it centres on the choice.
            // At the ends the lens may overhang the pill, as a lifted glass lens does.
            let centre = dragX.map { min(max($0, segment / 2), width - segment / 2) }
                ?? segment * (CGFloat(selection.index) + 0.5)

            let lensHeight = lifted ? Self.liftedHeight : Self.restingHeight
            let lensFrame = CGRect(x: centre - lensWidth / 2, y: (geometry.size.height - lensHeight) / 2,
                                   width: lensWidth, height: lensHeight)
            let anchor = UnitPoint(x: centre / max(width, 1), y: 0.5)

            ZStack(alignment: .topLeading) {
                if !lifted || !Self.hasLiquidGlass {
                    lens(lifted: lifted)
                        .frame(width: lensWidth, height: lensHeight)
                        .position(x: centre, y: geometry.size.height / 2)
                }

                if lifted, #available(macOS 26.0, *) {
                    // A clear Liquid Glass lens refracts the pill and what is behind it; the labels
                    // stay crisp on top, as in the system's own glass controls.
                    Color.clear
                        .glassEffect(.clear, in: Capsule())
                        .environment(\.colorScheme, .light)
                        .overlay { lensRim }
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                        .frame(width: lensWidth, height: lensHeight)
                        .position(x: centre, y: geometry.size.height / 2)
                    labels(segment: segment, height: geometry.size.height)
                } else if lifted && !reduceMotion {
                    // Refraction (macOS 14 and 15): outside the lens the labels are untouched; inside they are
                    // magnified, and along the rim they bend harder, as through a drop of glass.
                    labels(segment: segment, height: geometry.size.height)
                        .mask { LensCutout(lens: lensFrame, inside: false) }
                    labels(segment: segment, height: geometry.size.height)
                        .scaleEffect(1.22, anchor: anchor)
                        .mask { LensCutout(lens: lensFrame.insetBy(dx: 6, dy: 6), inside: true) }
                    labels(segment: segment, height: geometry.size.height)
                        .scaleEffect(1.6, anchor: anchor)
                        .blur(radius: 0.7)
                        .mask {
                            Capsule()
                                .strokeBorder(lineWidth: 6)
                                .frame(width: lensFrame.width, height: lensFrame.height)
                                .position(x: lensFrame.midX, y: lensFrame.midY)
                        }
                    lensRim
                        .frame(width: lensWidth, height: lensHeight)
                        .position(x: centre, y: geometry.size.height / 2)
                } else {
                    labels(segment: segment, height: geometry.size.height)
                }
            }
            .allowsHitTesting(false)
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

    private func labels(segment: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(PoachCaptureTimer.allCases) { option in
                Text(option.shortTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(option == selection ? Color(white: 0.09) : Color(white: 0.45))
                    .frame(width: segment, height: height)
            }
        }
        .frame(height: height)
    }

    /// The lifted lens's bright rim, drawn over the refracted labels.
    private var lensRim: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .black.opacity(0.1)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.2
            )
    }

    /// Resting: a soft white thumb with a hairline edge. Lifted: an almost clear lens with a
    /// bright rim that fades downward and a soft shadow, so the labels show through it.
    @ViewBuilder private func lens(lifted: Bool) -> some View {
        if lifted {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.35), .black.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2
                    )
                }
                .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        } else {
            Capsule()
                .fill(Color.white.opacity(0.9))
                .overlay { Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 0.5)
        }
    }
}
