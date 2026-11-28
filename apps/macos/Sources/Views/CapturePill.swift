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
    static let size = CGSize(width: 176, height: 48)
    static let bottomInset: CGFloat = 26
    /// Room around the pill in its own panels, so the timer lens and the shadow are not clipped.
    static let panelMargin: CGFloat = 16

    /// Bottom centre of `screen`, where the selection controls sit since `507bd90`.
    @MainActor
    static func frame(on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + bottomInset, width: size.width, height: size.height)
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

    /// The selected area's corner radius: the pill's own (half its height), so the outline and the
    /// pill that leaves it read as one shape. Smaller areas are held to half their shorter side.
    static func areaCornerRadius(for area: CGRect) -> CGFloat {
        min(size.height / 2, min(area.width, area.height) / 2)
    }

    /// The centres of the three buttons, the same as the Off · 3s · 10s options, so the icons sit
    /// where the timer choices do.
    static var slotCentres: [CGFloat] {
        let lens = CaptureTimerLensLayout(pillWidth: Double(size.width), pillHeight: Double(size.height))
        return (0..<3).map { CGFloat(lens.centre(of: $0)) }
    }

    /// The span of slot `index` when the three slots cover the whole pill, split halfway between
    /// their centres (the unified pill's glass cells).
    static func slotSpan(_ index: Int) -> (minX: CGFloat, maxX: CGFloat) {
        let c = slotCentres
        let lower = index == 0 ? 0 : (c[index - 1] + c[index]) / 2
        let upper = index == c.count - 1 ? size.width : (c[index] + c[index + 1]) / 2
        return (lower, upper)
    }

    static var panelSize: CGSize {
        CGSize(width: size.width + panelMargin * 2, height: size.height + panelMargin * 2)
    }
}

/// How the pill builds its glass on macOS 26. Earlier systems always draw `.custom`.
/// Stored under `storageKey`; the design lab switches it to compare the variants.
enum CapturePillStyle: String, CaseIterable, Identifiable {
    /// One system glass capsule behind hand-drawn buttons and the custom timer lens.
    case custom
    /// Each button has its own system glass; `glassEffectUnion` merges them into one capsule.
    case unified

    static let storageKey = "capturePillStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .unified: "Unified glass"
        }
    }
}

/// Optical compression of the track under the lifted lens, in pill-local coordinates.
/// Layout and foreground labels are never resized by this effect.
struct CaptureTimerRefraction: Equatable, Sendable {
    var centre: CGFloat = 0
    var amount: CGFloat = 0
    static let inset: CGFloat = 3.5
    static let halfWidth = CGFloat(CaptureTimerLensLayout(
        pillWidth: CapturePillLayout.size.width, pillHeight: CapturePillLayout.size.height).liftedSize.width / 2)

    func compression(at x: CGFloat, halfHeight: CGFloat) -> CGFloat {
        // Keep the lens's straight middle level; spread the transition across its rounded sides.
        let shoulder = min(28, Self.halfWidth * 0.65)
        let t = min(max((Self.halfWidth - abs(x - centre)) / shoulder, 0), 1)
        let falloff = t * t * t * (t * (t * 6 - 15) + 10)
        return 1 - min(Self.inset / max(halfHeight, 1), 0.25) * min(max(amount, 0), 1) * falloff
    }

    func uniform(in frame: CGRect) -> SIMD4<Float> {
        SIMD4(Float(frame.minX + centre), Float(Self.halfWidth), Float(amount), Float(Self.inset))
    }
}

private struct CaptureTimerRefractionKey: PreferenceKey {
    static let defaultValue = CaptureTimerRefraction()
    static func reduce(value: inout CaptureTimerRefraction, nextValue: () -> CaptureTimerRefraction) {
        let next = nextValue()
        if next.centre > 0 { value = next }
    }
}

/// The original capsule, optically pinched near the lens. Its frame and centre stay fixed.
private struct CaptureTimerTrackShape: Shape {
    var refraction: CaptureTimerRefraction
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(refraction.centre, refraction.amount) }
        set { refraction.centre = newValue.first; refraction.amount = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard refraction.amount > 0.001 else { return Capsule().path(in: rect) }
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return Path() }
        let straight = max(0, rect.width - 2 * radius)
        let arc = CGFloat.pi * radius
        let perimeter = 2 * (straight + arc)
        var points: [CGPoint] = []
        for index in 0..<160 {
            var d = perimeter * CGFloat(index) / 160
            var point: CGPoint
            if d < straight {
                point = CGPoint(x: rect.minX + radius + d, y: rect.minY)
            } else if d < straight + arc {
                d -= straight
                let angle = d / radius - .pi / 2
                point = CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            } else if d < 2 * straight + arc {
                d -= straight + arc
                point = CGPoint(x: rect.maxX - radius - d, y: rect.maxY)
            } else {
                d -= 2 * straight + arc
                let angle = d / radius + .pi / 2
                point = CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            }
            point.y = rect.midY + (point.y - rect.midY) * refraction.compression(at: point.x - rect.minX, halfHeight: radius)
            points.append(point)
        }
        // Continuous tangents keep the glass highlight smooth through the shoulder. Straight
        // sections remain exactly horizontal, rather than exposing the sampled polygon's corners.
        var path = Path()
        path.move(to: points[0])
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let next = points[(index + 2) % points.count]
            path.addCurve(to: end,
                control1: CGPoint(x: start.x + (end.x - previous.x) / 6,
                                  y: start.y + (end.y - previous.y) / 6),
                control2: CGPoint(x: end.x - (next.x - start.x) / 6,
                                  y: end.y - (next.y - start.y) / 6))
        }
        path.closeSubpath()
        return path
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
    @AppStorage(CapturePillStyle.storageKey) private var storedStyle = CapturePillStyle.custom.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.capturePillExternalGlass) private var externalGlass
    @State private var timerRefraction = CaptureTimerRefraction()
    @FocusState private var optionsFocused: Bool
    @Namespace private var glassSpace

    private static let activeTint = Color(red: 0.77, green: 0.42, blue: 0)
    private static let activeFill = Color(red: 0.99, green: 0.90, blue: 0.78)
    /// The unified pill's chosen-timer colour, sampled from a reference the user shared (#F0DA5A).
    /// The custom pill keeps `activeTint`: on its pale fill and light glass this yellow is unreadable.
    private static let activeYellow = Color(red: 0.94, green: 0.855, blue: 0.35)
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
    private var style: CapturePillStyle { CapturePillStyle(rawValue: storedStyle) ?? .custom }

    var body: some View {
        if #available(macOS 26.0, *), externalGlass || style != .custom {
            nativeBody
        } else {
            customBody
        }
    }

    private var customBody: some View {
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
        .background { CapturePillGlass(refraction: timerRefraction) }
        .onPreferenceChange(CaptureTimerRefractionKey.self) { value in
            withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                timerRefraction = value
            }
        }
        .overlay { progressEdge }
        .background { shortcuts }
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.1), value: timerExpanded)
        // The glass is forced light, so its content must be too, whatever the system scheme.
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }

    private var buttons: some View {
        HStack(spacing: CapturePillTimerButton.spacing) {
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

// MARK: - System glass variants (macOS 26)

@available(macOS 26.0, *)
extension CapturePill {
    /// Only the background participates in the glass union and its morph. The buttons and
    /// timer labels stay above the entire container, outside its refraction and magnification.
    fileprivate var nativeBody: some View {
        ZStack {
            GlassEffectContainer(spacing: 6) {
                ZStack {
                    if timerExpanded && isSelecting {
                        Color.clear
                            .frame(width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
                            .glassEffect(externalGlass ? .identity : .regular,
                                         in: CaptureTimerTrackShape(refraction: timerRefraction))
                            .glassEffectID("timer", in: glassSpace)
                    } else {
                        HStack(spacing: 0) {
                            nativeButtonGlass(id: "timer", slot: 0)
                            nativeButtonGlass(id: "primary", slot: 1)
                            nativeButtonGlass(id: "cancel", slot: 2)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if timerExpanded && isSelecting {
                nativeOptions
                    .transition(.opacity)
            } else {
                nativeButtons
                    .transition(.opacity)
            }
        }
        .opacity(controlsOpacity)
        .allowsHitTesting(controlsOpacity > 0.5)
        .frame(width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
        .overlay { progressEdge }
        .background { shortcuts }
        .onPreferenceChange(CaptureTimerRefractionKey.self) { value in
            withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                timerRefraction = value
            }
        }
        // Unlike `.custom`, the glass is not forced light: it adapts to what is behind it like
        // the system's controls, and the `.primary` icons follow it.
        .animation(reduceMotion ? nil : .bouncy(duration: 0.38), value: timerExpanded)
    }

    private var nativeButtons: some View {
        HStack(spacing: 0) {
            nativeButton(slot: 0, enabled: isSelecting, prominent: false) { timerExpanded = true } label: {
                CaptureTimerGlyph(timer: timer)
                    .foregroundStyle(timer == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(Self.activeYellow))
            }
            .accessibilityLabel("Timer")
            .accessibilityValue(timer.spokenTitle)
            .accessibilityHint("Shows timer options")
            .help("Capture timer: \(timer.spokenTitle) (T)")

            nativeButton(slot: 1, enabled: primaryEnabled, prominent: true, action: onPrimary) {
                Image(systemName: primarySymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(primaryLabel)
            .accessibilityValue(recordingValue ?? "")
            .help(primaryHelp)
            .keyboardShortcut(.defaultAction)

            nativeButton(slot: 2, enabled: cancelEnabled, prominent: false, action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .keyboardShortcut(cancelEnabled ? .cancelAction : nil)
            .accessibilityLabel(phase == .countdown ? "Cancel countdown" : "Cancel selection")
            .help(phase == .countdown ? "Cancel countdown (Esc)" : "Cancel (Esc)")
        }
    }

    /// The tint of the prominent button: red to record or stop, ink for screenshots.
    private var prominentTint: Color {
        if isRecording { return .red }
        return screenshot ? PoachPalette.ink : .red
    }

    private func nativeButton<Label: View>(slot: Int, enabled: Bool, prominent: Bool, action: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        // Foreground only: never apply glassEffect or a scale transform to the button/label.
        let span = CapturePillLayout.slotSpan(slot)
        let width = span.maxX - span.minX
        return Button(action: action) {
            label()
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 44, height: 32)
                .background { if prominent { Capsule().fill(prominentTint) } }
                .offset(x: CapturePillLayout.slotCentres[slot] - (span.minX + width / 2))
                .frame(width: width, height: CapturePillLayout.size.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : Self.dimmed)
    }

    private func nativeButtonGlass(id: String, slot: Int) -> some View {
        let span = CapturePillLayout.slotSpan(slot)
        return Color.clear
            .frame(width: span.maxX - span.minX, height: CapturePillLayout.size.height)
            .glassEffect(externalGlass ? .identity : .regular, in: Capsule())
            .glassEffectUnion(id: "pill", namespace: glassSpace)
            .glassEffectID(id, in: glassSpace)
    }

    /// Off · 3s · 10s with the same lens picker as `.custom`, on the pill's glass.
    private var nativeOptions: some View {
        CaptureTimerLensPicker(
            selection: Binding(get: { timer }, set: { storedSeconds = $0.rawValue }),
            whiteLabels: true,
            onCommit: { timerExpanded = false }
        )
        .frame(width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
        .focusable()
        .focused($optionsFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { storedSeconds = timer.stepped(by: -1).rawValue; return .handled }
        .onKeyPress(.rightArrow) { storedSeconds = timer.stepped(by: 1).rawValue; return .handled }
        .onKeyPress(.return) { timerExpanded = false; return .handled }
        .onAppear { optionsFocused = true }
    }
}

/// Removes the centre *after* rendering glass. The optical shape remains a convex rounded
/// rectangle, without the extra inward-facing refraction a ring-shaped glass material creates.
struct CaptureGlassPerimeterMask: View {
    let area: CGRect?
    var pill: CGRect? = nil
    private let opticalWidth: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            if let area {
                let inset = min(opticalWidth, min(area.width, area.height) / 4)
                let inner = area.insetBy(dx: inset, dy: inset)
                if inner.width > 0, inner.height > 0 {
                    var cutout = Path(roundedRect: inner,
                                      cornerRadius: max(0, CapturePillLayout.areaCornerRadius(for: area) - inset),
                                      style: .continuous)
                    if let pill { cutout = cutout.subtracting(Capsule().path(in: pill)) }
                    path.addPath(cutout)
                }
            }
            // Feather the native fallback as well; a one-point blur exposes the cutout edge.
            context.addFilter(.blur(radius: min(8, area.map { min($0.width, $0.height) / 8 } ?? 8)))
            context.fill(path, with: .color(.white), style: FillStyle(eoFill: true))
        }
    }
}

/// The surface is left unmasked while participating in the drop's container; that container
/// applies the cutout to the whole liquid union, preserving its neck at the selection's edge.
@available(macOS 26.0, *)
struct CaptureAreaGlass: View {
    let area: CGRect
    var inLiquidUnion = false
    @Environment(\.captureGlassBackdrop) private var backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if let backdrop, backdrop.isReady, !reduceTransparency, contrast != .increased, CaptureLiquidGlass.isSupported {
                CaptureLiquidGlass(backdrop: backdrop, area: area)
            } else {
                Color.clear
                    .frame(width: area.width, height: area.height)
                    .glassEffect(.clear, in: RoundedRectangle(
                        cornerRadius: CapturePillLayout.areaCornerRadius(for: area), style: .continuous))
                    .position(x: area.midX, y: area.midY)
                    .mask { CaptureGlassPerimeterMask(area: inLiquidUnion ? nil : area) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The area pill's entrance, like a drop of liquid leaving the selection outline:
/// 1–2. in one continuous, accelerating move, the outline swells at `origin` into a drop held by
///    a neck that stretches and snaps (a metaball: blurred shapes cut at half opacity), and the
///    free drop keeps falling to the pill's centre;
/// 3. it grows into the pill, its white becoming the pill's rim while the glass shows through;
/// 4. the buttons fade in.
/// With Reduce Motion the pill simply appears.
struct CapturePillDropIn<Pill: View>: View {
    /// Where the drop leaves the outline, in the parent's coordinates.
    let origin: CGPoint
    /// The pill's final frame, in the parent's coordinates.
    let frame: CGRect
    /// The clear selection surface the controls detach from. `nil` is used by pill-only previews.
    var outline: CGRect? = nil
    let pill: (Double) -> Pill

    @State private var start = Date()
    @State private var finished = false
    @State private var timerRefraction = CaptureTimerRefraction()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.captureGlassBackdrop) private var backdrop
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // The glass drop (after a reference the user recorded on Nov 26): a bead of glass swells on
    // the outline and a blob of glass leaves it on a bridge that stretches, thins and snaps, then
    // grows into the pill with a small wobble.
    private static var glassEmerge: Double { 0.14 }
    private static var glassTravel: Double { 0.46 }
    private static var glassSettle: Double { 0.12 }
    private static var glassTotal: Double { glassEmerge + glassTravel + glassSettle + fade }
    /// Shapes closer than this melt together in the glass container.
    private static var glassSpacing: CGFloat { 30 }

    /// The neck holds the drop for this part of the travel, then snaps.
    private static var pinch: Double { 0.24 }
    private static var fall: Double { 0.06 }
    private static var grow: Double { 0.38 }
    private static var fade: Double { 0.12 }
    private static var total: Double { pinch + fall + grow + fade }
    private static var dropRadius: CGFloat { 8 }

    var body: some View {
        if #available(macOS 26.0, *) {
            // Keep the same container, glass and controls alive after landing. Replacing the
            // blob with a second pill would change material and reset timer focus at the seam.
            TimelineView(.animation(paused: finished || reduceMotion)) { timeline in
                glassContent(at: reduceMotion || finished ? Self.glassTotal : timeline.date.timeIntervalSince(start))
            }
            .task {
                guard !reduceMotion else { return }
                start = Date()
                do { try await Task.sleep(for: .seconds(Self.glassTotal)) } catch { return }
                finished = true
            }
        } else if reduceMotion || finished {
            pill(1).position(x: frame.midX, y: frame.midY)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                content(at: t)
            }
            .task {
                do { try await Task.sleep(for: .seconds(Self.total + 0.05)) } catch { return }
                finished = true
            }
        }
    }

    @ViewBuilder
    private func content(at t: Double) -> some View {
        let direction: CGFloat = frame.midY >= origin.y ? 1 : -1
        let growStart = Self.pinch + Self.fall
        // One path from the outline to the pill's centre: it starts slowly and only speeds up,
        // so the drop never stops between leaving the outline and landing.
        let travel = Self.easeIn(t / growStart)
        let centre = CGPoint(x: origin.x + (frame.midX - origin.x) * travel,
                             y: origin.y + (frame.midY - origin.y) * travel)
        ZStack(alignment: .topLeading) {
            if t < Self.pinch {
                // The outline swells into a drop on a stretching neck.
                let p = Self.easeInOut(t / Self.pinch)
                // Wide and flat at first, rounder as it hangs lower.
                goo(drop: centre, radius: 3 + (Self.dropRadius - 3) * p, stretch: 1.9 - 0.9 * p, direction: direction)
            } else if t < growStart {
                // The free drop, stretched along its path as it speeds up.
                let f = CGFloat(min(max((t - Self.pinch) / Self.fall, 0), 1))
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

    /// One optical surface for both the selection and the departing capsule. Metal provides
    /// the reference's RGB dispersion; native glass is the fallback when sampling is unavailable.
    @available(macOS 26.0, *)
    private func glassContent(at t: Double) -> some View {
        let travelStart = Self.glassEmerge
        let landed = travelStart + Self.glassTravel + Self.glassSettle
        let emerge = Self.easeInOut(t / Self.glassEmerge)
        let travel = Self.easeInOut((t - travelStart) / Self.glassTravel)
        let growStart = travelStart + Self.glassTravel * 0.45
        let grow = Self.spring((t - growStart) / (landed - growStart), damping: 6, frequency: 7)
        let blob = max(0.01, 24 * emerge)
        let centre = CGPoint(x: origin.x + (frame.midX - origin.x) * travel,
                             y: origin.y + (frame.midY - origin.y) * travel)
        let release = Self.easeInOut((t - travelStart - 0.16) / 0.28)
        let controls = min(max((t - landed + 0.06) / Self.fade, 0), 1)
        let blobFrame = CGRect(x: centre.x - (blob + (frame.width - blob) * grow) / 2,
                               y: centre.y - (blob + (frame.height - blob) * grow) / 2,
                               width: max(0.01, blob + (frame.width - blob) * grow),
                               height: max(0.01, blob + (frame.height - blob) * grow))
        return ZStack(alignment: .topLeading) {
            Group {
                if let backdrop, backdrop.isReady, !reduceTransparency, contrast != .increased, CaptureLiquidGlass.isSupported {
                    CaptureLiquidGlass(backdrop: backdrop, area: outline, pill: blobFrame,
                                       connection: Self.glassSpacing * (1 - release),
                                       timerRefraction: timerRefraction.uniform(in: frame))
                } else {
                    GlassEffectContainer(spacing: Self.glassSpacing * (1 - release)) {
                        ZStack(alignment: .topLeading) {
                            if let outline {
                                CaptureAreaGlass(area: outline, inLiquidUnion: true)
                                    .environment(\.captureGlassBackdrop, nil)
                            } else {
                                Color.clear
                                    .frame(width: max(0.01, 88 * emerge * (1 - release)),
                                           height: max(0.01, 14 * emerge * (1 - release)))
                                    .glassEffect(.clear, in: Capsule())
                                    .position(origin)
                            }
                            Color.clear
                                .frame(width: max(0.01, blob + (frame.width - blob) * grow),
                                       height: max(0.01, blob + (frame.height - blob) * grow))
                                .glassEffect(.clear, in: CaptureTimerTrackShape(refraction: timerRefraction))
                                .position(centre)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .mask { CaptureGlassPerimeterMask(area: outline, pill: blobFrame) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // Only the controls fade. The glass is never masked, so the timer's lifted lens
            // can continue to overhang the capsule after the drop has settled.
            pill(controls)
                .environment(\.capturePillExternalGlass, true)
                .environment(\.colorScheme, .dark)
                .position(x: frame.midX, y: frame.midY)
        }
        .onPreferenceChange(CaptureTimerRefractionKey.self) { value in
            withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                timerRefraction = value
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
    var refraction = CaptureTimerRefraction()
    @Environment(\.capturePillExternalGlass) private var externalGlass

    var body: some View {
        Group {
            if externalGlass {
                Color.clear
            } else if #available(macOS 26.0, *) {
                // Light glass even in Dark Mode or over dark windows, so the dark icons stay legible.
                Color.clear.glassEffect(.regular, in: CaptureTimerTrackShape(refraction: refraction))
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

private struct CapturePillExternalGlassKey: EnvironmentKey {
    static let defaultValue = false
}

private struct CapturePillBlendingKey: EnvironmentKey {
    static let defaultValue = NSVisualEffectView.BlendingMode.behindWindow
}

private struct TimerLensPreviewKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The area drop-in owns the capsule's glass; the pill supplies controls without a second material.
    var capturePillExternalGlass: Bool {
        get { self[CapturePillExternalGlassKey.self] }
        set { self[CapturePillExternalGlassKey.self] = newValue }
    }

    /// Design lab only: holds the timer lens as if pressed at this x, to inspect the lifted lens.
    var timerLensPreviewX: CGFloat? {
        get { self[TimerLensPreviewKey.self] }
        set { self[TimerLensPreviewKey.self] = newValue }
    }

    /// `.behindWindow` for the pill's own panels and overlays; `.withinWindow` inside a regular window.
    var capturePillBlending: NSVisualEffectView.BlendingMode {
        get { self[CapturePillBlendingKey.self] }
        set { self[CapturePillBlendingKey.self] = newValue }
    }
}

/// Where the ⏱ button sits inside the pill: the first of three 44 × 32 buttons centred on the
/// Off · 3s · 10s option centres (`CapturePillLayout.slotCentres`).
private enum CapturePillTimerButton {
    static let size = CGSize(width: 44, height: 32)
    static var spacing: CGFloat {
        let c = CapturePillLayout.slotCentres
        return c[1] - c[0] - size.width
    }
    static var origin: CGPoint {
        CGPoint(x: CapturePillLayout.slotCentres[0] - size.width / 2, y: (CapturePillLayout.size.height - size.height) / 2)
    }
}

/// ⏱ when the timer is off. With 3s or 10s chosen, the ring of the user's icons in
/// `apps/macos/Assets/TimerIcons` (a stem and an open circle, drawn from the same path so it takes
/// the button's colour) with the seconds inside as text.
private struct CaptureTimerGlyph: View {
    let timer: PoachCaptureTimer

    /// Both drawings have an explicit 18 pt ink diameter. Shape strokes are applied after
    /// their path is sized, so subtract the final stroke before converting the 19-unit ring.
    private static let diameter: CGFloat = 18
    private static let ringStroke: CGFloat = 1.875
    private static let ringFrame: CGFloat = (diameter - ringStroke) * 24 / 19

    var body: some View {
        Group {
            if timer == .off {
                Image(systemName: "timer")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .frame(width: Self.diameter, height: Self.diameter)
            } else {
                ZStack {
                    TimerIconShape()
                        .stroke(style: StrokeStyle(lineWidth: Self.ringStroke, lineCap: .round, lineJoin: .round))
                    Text("\(timer.seconds)")
                        .font(.system(size: timer.seconds >= 10 ? 8.5 : 10, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(width: Self.ringFrame, height: Self.ringFrame)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The ring shared by `timer-3.svg` and `timer-10.svg` (24 × 24 viewBox), scaled to the frame:
/// M 12 4.5 V 2.5 A 9.5 9.5 0 1 1 5.1 5.5, a stem at the top, then the circle clockwise around to
/// the upper left, leaving it open between the stem and about 10:30.
private struct TimerIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 4.5))
        p.addLine(to: CGPoint(x: 12, y: 2.5))
        p.addArc(center: CGPoint(x: 12, y: 12), radius: 9.5, startAngle: .degrees(-90),
                 endAngle: .radians(atan2(5.5 - 12, 5.1 - 12)), clockwise: false)
        let scale = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
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

/// The timer options as a segmented control with a clear lens (Poach brief `FDBFE307…`, and a
/// reference the user shared on Nov 26). At rest the chosen option sits under a pill inside the
/// pill; while pressed the lens grows into a wider capsule that stands out of the pill and follows
/// the pointer, and the option under it becomes the choice at once. On release it settles back
/// with a spring. The lens is only a bright rim, so the labels show through it unchanged.
private struct CaptureTimerLensPicker: View {
    @Binding var selection: PoachCaptureTimer
    /// White labels, like the unified pill's icons; dark ones on the custom pill's light glass.
    var whiteLabels = false
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// `.custom` forces light; `.unified` follows the system, so the rim adapts.
    @Environment(\.colorScheme) private var colorScheme
    /// Pointer x while pressed; `nil` when the lens rests on `selection`.
    @State private var pressedX: CGFloat?
    @Environment(\.timerLensPreviewX) private var previewX
    private var dragX: CGFloat? { pressedX ?? previewX }

    var body: some View {
        GeometryReader { geometry in
            let layout = CaptureTimerLensLayout(pillWidth: geometry.size.width, pillHeight: geometry.size.height)
            let lifted = dragX != nil
            let size = lifted ? layout.liftedSize : layout.restingSize
            // While pressed the lens follows the pointer, held between the end positions where it
            // is concentric with the pill; at rest it sits on the choice.
            let centre = dragX.map { CGFloat(layout.clampedCentre(Double($0))) }
                ?? CGFloat(layout.centre(of: selection.index))

            ZStack(alignment: .topLeading) {
                // Only the lens perimeter refracts the underlying track; its centre is clear.
                lens(lifted: lifted)
                    .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                    .position(x: centre, y: geometry.size.height / 2)

                // Labels are foreground ink, above both the track and the lens's optical rim.
                ForEach(PoachCaptureTimer.allCases) { option in
                    label(option)
                        .position(x: CGFloat(layout.centre(of: option.index)), y: geometry.size.height / 2)
                }
            }
            .preference(key: CaptureTimerRefractionKey.self,
                        value: CaptureTimerRefraction(centre: centre,
                            amount: lifted && !reduceTransparency && contrast != .increased ? 1 : 0))
            .allowsHitTesting(false)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let x = value.location.x
                        let option = PoachCaptureTimer.allCases[layout.index(atX: Double(x))]
                        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                            pressedX = x
                            selection = option
                        }
                    }
                    .onEnded { value in
                        let option = PoachCaptureTimer.allCases[layout.index(atX: Double(value.location.x))]
                        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.68)) {
                            selection = option
                            pressedX = nil
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

    private func label(_ option: PoachCaptureTimer) -> some View {
        let chosen = option == selection
        return Text(option.shortTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(whiteLabels
                ? AnyShapeStyle(Color.white.opacity(chosen ? 1 : 0.6))
                : AnyShapeStyle(chosen ? Color(white: 0.09) : Color(white: 0.45)))
            // White text needs a soft edge to stay legible over light backgrounds.
            .shadow(color: .black.opacity(whiteLabels ? 0.35 : 0), radius: 1.5, x: 0, y: 0.5)
            .fixedSize()
    }

    /// Native convex glass, masked after rendering so only its four-point perimeter is
    /// visible. There is no scaled track copy or optical surface over the lens's centre.
    private var lensEdgeGlass: some View {
        Group {
            if !reduceTransparency, contrast != .increased {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: Capsule())
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            } else {
                Color.clear
            }
        }
        .mask { Capsule().strokeBorder(.white, lineWidth: 4).blur(radius: 1) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var lensRim: some View {
        let dark = colorScheme == .dark
        return Capsule().strokeBorder(
            LinearGradient(stops: [
                .init(color: .white.opacity(dark ? 0.5 : 0.7), location: 0),
                .init(color: .white.opacity(0.12), location: 0.4),
                .init(color: .black.opacity(dark ? 0.35 : 0.15), location: 0.7),
                .init(color: .white.opacity(0.25), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
    }

    /// At rest the chosen option sits on an opaque pill with no outline: grey under the unified
    /// pill's white labels, white under the custom pill's dark ones.
    private var thumbColor: Color {
        guard whiteLabels else { return .white }
        return Color(white: colorScheme == .dark ? 0.4 : 0.5)
    }

    /// Preserve the resting thumb and both spring-driven sizes. Only the lifted material
    /// changes: a clear centre, refracting edge and directional highlight, like the reference.
    private func lens(lifted: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(thumbColor)
                .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 0.5)
                .opacity(lifted ? 0 : 1)
            lensEdgeGlass
                .overlay { lensRim }
                .shadow(color: .black.opacity(0.12), radius: 1.4, x: 0, y: 1.6)
                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 8)
                .opacity(lifted ? 1 : 0)
        }
    }
}
