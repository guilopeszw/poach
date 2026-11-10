import AppKit
import SwiftUI

/// A dragged area on one display. `rect` is screen-local with a top-left origin.
struct SelectedRegion {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

/// What the person chose to capture.
enum CaptureTarget {
    case area(SelectedRegion)
    case display(CGDirectDisplayID)
    case window(CaptureWindowCandidate)
}

/// Poach-owned selection for every capture mode. It replaces Apple's content-sharing
/// picker so the timer control sits in the same panel for area, display and window.
/// Selection never runs the countdown; `CaptureCountdownController` does that afterwards.
@MainActor
final class CaptureSelectionWindowController {
    static let shared = CaptureSelectionWindowController()
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CaptureTarget, Error>?

    func select(mode: PoachCaptureMode, screenshot: Bool) async throws -> CaptureTarget {
        NSApp.unhide(nil)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        // Read the window list before Poach's own overlays exist.
        let windows: [CaptureWindowCandidate]
        if mode == .window {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            windows = CaptureTargetGeometry.selectableWindows(
                CaptureTargetGeometry.candidates(fromWindowInfo: info),
                excludingPID: ProcessInfo.processInfo.processIdentifier
            )
        } else {
            windows = []
        }
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (screen, id)
        }
        guard !screens.isEmpty else { throw ScreenCaptureError.noDisplay }
        let primaryHeight = NSScreen.screens[0].frame.height
        let state = CaptureSelectionState(
            mode: mode,
            screenshot: screenshot,
            windows: windows,
            displays: screens.map { CaptureSelectionState.Display(id: $0.1, name: $0.0.localizedName) }
        )
        state.displayTarget = screens.first { $0.0.frame.contains(NSEvent.mouseLocation) }?.1 ?? screens[0].1
        state.onFinish = { [weak self] result in self?.finish(result) }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for (screen, displayID) in screens {
                let panel = CaptureSelectionPanel(
                    contentRect: NSRect(origin: .zero, size: screen.frame.size),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.title = "Poach — Select what to capture"
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.hasShadow = false
                panel.becomesKeyOnlyIfNeeded = false
                panel.isMovable = false
                panel.acceptsMouseMovedEvents = true
                let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
                panel.contentView = TransparentHostingView(rootView: CaptureSelectionView(
                    state: state,
                    displayID: displayID,
                    screenTopLeft: origin
                ))
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.setFrame(screen.frame, display: true)
                panels.append(panel)
                panel.orderFrontRegardless()
                if screen.frame.contains(NSEvent.mouseLocation) {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        }
    }

    private func finish(_ result: Result<CaptureTarget, Error>) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if case .failure = result {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "Poach" })?.makeKeyAndOrderFront(nil)
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Selection state shared by the overlays on every screen.
@MainActor
final class CaptureSelectionState: ObservableObject {
    struct Display {
        let id: CGDirectDisplayID
        let name: String
    }

    let mode: PoachCaptureMode
    let screenshot: Bool
    let windows: [CaptureWindowCandidate]
    let displays: [Display]
    @Published var displayTarget: CGDirectDisplayID?
    @Published var windowTarget: CaptureWindowCandidate?
    @Published var windowLocked = false
    @Published var timerExpanded = false
    var onFinish: (Result<CaptureTarget, Error>) -> Void = { _ in }

    init(mode: PoachCaptureMode, screenshot: Bool, windows: [CaptureWindowCandidate], displays: [Display]) {
        self.mode = mode
        self.screenshot = screenshot
        self.windows = windows
        self.displays = displays
    }

    /// Pointer moved to `point` (global top-left coordinates) over `displayID`.
    func hover(at point: CGPoint, displayID: CGDirectDisplayID) {
        switch mode {
        case .fullScreen: displayTarget = displayID
        case .window where !windowLocked: windowTarget = CaptureTargetGeometry.window(at: point, in: windows)
        default: break
        }
    }

    /// Click at `point`: locks the window under it (window mode) or picks the display.
    func click(at point: CGPoint, displayID: CGDirectDisplayID) {
        switch mode {
        case .fullScreen:
            displayTarget = displayID
        case .window:
            windowTarget = CaptureTargetGeometry.window(at: point, in: windows)
            windowLocked = windowTarget != nil
        default: break
        }
    }

    func cycle(forward: Bool) {
        switch mode {
        case .fullScreen:
            let current = displays.firstIndex { $0.id == displayTarget }
            if let index = CaptureTargetGeometry.cycledIndex(from: current, count: displays.count, forward: forward) {
                displayTarget = displays[index].id
            }
        case .window:
            let current = windows.firstIndex { $0.windowID == windowTarget?.windowID }
            if let index = CaptureTargetGeometry.cycledIndex(from: current, count: windows.count, forward: forward) {
                windowTarget = windows[index]
                windowLocked = true
            }
        default: break
        }
    }

    var targetName: String? {
        switch mode {
        case .fullScreen: displays.first { $0.id == displayTarget }?.name
        case .window: windowTarget?.spokenName
        default: nil
        }
    }

    func cancel() { onFinish(.failure(ScreenCaptureError.selectionCancelled)) }
    func choose(_ target: CaptureTarget) { onFinish(.success(target)) }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Clears the hosting view's backing so overlays stay transparent.
@MainActor
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
        window?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

private struct CaptureSelectionView: View {
    @ObservedObject var state: CaptureSelectionState
    let displayID: CGDirectDisplayID
    /// This screen's top-left corner in global top-left coordinates.
    let screenTopLeft: CGPoint
    @State private var origin: CGPoint?
    @State private var current: CGPoint?

    private var dragSelection: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    /// The highlighted target on this screen, in local coordinates. `nil` dims the whole screen.
    private var highlight: CGRect? {
        switch state.mode {
        case .selectedPortion:
            return dragSelection
        case .fullScreen:
            return nil
        case .window:
            guard let frame = state.windowTarget?.frame else { return nil }
            return frame.offsetBy(dx: -screenTopLeft.x, dy: -screenTopLeft.y)
        }
    }

    private var isTargetScreen: Bool { state.mode == .fullScreen && state.displayTarget == displayID }

    private var canStart: Bool {
        switch state.mode {
        case .selectedPortion: (dragSelection?.width ?? 0) >= 32 && (dragSelection?.height ?? 0) >= 32
        case .fullScreen: state.displayTarget != nil
        case .window: state.windowTarget != nil
        }
    }

    private var title: String {
        switch state.mode {
        case .selectedPortion:
            if dragSelection == nil { return "Drag to select an area" }
            return state.screenshot ? "Ready to take a screenshot" : "Ready to record"
        case .fullScreen:
            return state.screenshot ? "Capture this screen" : "Record this screen"
        case .window:
            return state.windowTarget?.spokenName ?? (state.screenshot ? "Click a window to capture" : "Click a window to record")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Canvas { context, size in
                    if isTargetScreen {
                        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                        context.stroke(Path(frame), with: .color(.white), lineWidth: 2)
                        return
                    }
                    var mask = Path(CGRect(origin: .zero, size: size))
                    if let highlight, highlight.width > 3, highlight.height > 3 { mask.addRect(highlight) }
                    context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))
                    if let highlight {
                        context.stroke(Path(highlight), with: .color(.white), lineWidth: 2)
                        context.stroke(Path(highlight.insetBy(dx: 3, dy: 3)), with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase { state.hover(at: global(point), displayID: displayID) }
                }
                .gesture(selectionGesture(in: geometry.size))
                .accessibilityElement()
                .accessibilityLabel(state.mode == .selectedPortion ? "Capture area" : "Capture target")
                .accessibilityValue(state.targetName ?? "None")
                .accessibilityHint(state.mode == .selectedPortion ? "Drag to select an area" : "Press Tab to choose the next target")

                CaptureSelectionControls(
                    title: title,
                    screenshot: state.screenshot,
                    canStart: canStart,
                    timerExpanded: $state.timerExpanded,
                    onStart: start,
                    onCancel: state.cancel
                )
                .padding(.bottom, 26)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: UserDefaults.standard.string(forKey: "windowEdge") == "left" ? .leading : .trailing)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.clear)
        .background {
            if state.mode != .selectedPortion {
                Group {
                    Button("") { state.cycle(forward: true) }.keyboardShortcut(.tab, modifiers: [])
                    Button("") { state.cycle(forward: false) }.keyboardShortcut(.tab, modifiers: [.shift])
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.light)
        .onExitCommand {
            if state.timerExpanded { state.timerExpanded = false } else { state.cancel() }
        }
    }

    private func selectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.mode == .selectedPortion else { return }
                origin = clamped(value.startLocation, to: size)
                current = clamped(value.location, to: size)
            }
            .onEnded { value in
                guard state.mode != .selectedPortion else { return }
                state.click(at: global(value.location), displayID: displayID)
            }
    }

    private func start() {
        guard canStart else { return }
        switch state.mode {
        case .selectedPortion:
            guard let area = dragSelection?.integral else { return }
            state.choose(.area(SelectedRegion(displayID: displayID, rect: area)))
        case .fullScreen:
            guard let id = state.displayTarget else { return }
            state.choose(.display(id))
        case .window:
            guard let window = state.windowTarget else { return }
            state.choose(.window(window))
        }
    }

    private func global(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenTopLeft.x, y: local.y + screenTopLeft.y)
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }
}

/// The white selection panel: ⏱ · ● · ✕ (⏱ · 📷 · ✕ for screenshots).
private struct CaptureSelectionControls: View {
    let title: String
    let screenshot: Bool
    let canStart: Bool
    @Binding var timerExpanded: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    @AppStorage(PoachCaptureTimer.storageKey) private var storedSeconds = PoachCaptureTimer.off.rawValue

    private var timer: PoachCaptureTimer { PoachCaptureTimer(storedSeconds: storedSeconds) }

    private var startHelp: String {
        switch (screenshot, timer) {
        case (true, .off): "Take screenshot (Return)"
        case (true, _): "Take a screenshot after \(timer.spokenTitle) (Return)"
        case (false, .off): "Start recording (Return)"
        case (false, _): "Start the \(timer.spokenTitle) countdown (Return)"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)

            HStack(spacing: 10) {
                PoachCaptureTimerControl(isExpanded: $timerExpanded)

                if !timerExpanded {
                    Button(action: onStart) {
                        Image(systemName: screenshot ? "camera" : "circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 32)
                            .background(screenshot ? PoachPalette.ink : Color.red, in: RoundedRectangle(cornerRadius: 9))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .accessibilityLabel(screenshot ? "Take screenshot" : "Start recording")
                    .help(startHelp)
                    .keyboardShortcut(.defaultAction)

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 32)
                            .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel selection")
                    .help("Cancel (Esc)")
                }
            }
        }
        .frame(width: 262, height: 116)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background {
            // Space starts like Return and T toggles the timer; both only while this overlay is key.
            Group {
                Button("", action: onStart)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!canStart || timerExpanded)
                Button("") { timerExpanded.toggle() }
                    .keyboardShortcut("t", modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }
}
