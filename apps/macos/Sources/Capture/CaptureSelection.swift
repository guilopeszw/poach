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
    private var spaceObserver: NSObjectProtocol?

    func select(mode: PoachCaptureMode, screenshot: Bool) async throws -> CaptureTarget {
        NSApp.unhide(nil)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        let windows = mode == .window ? Self.visibleWindows() : []
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
        if mode == .window {
            // The overlay follows every desk, but the window list only covers the desk that was
            // active when it was read. Reload it whenever the person switches desks.
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak state] _ in
                MainActor.assumeIsolated {
                    state?.reloadWindows(Self.visibleWindows(), pointer: Self.pointerTopLeft())
                    // WindowServer can report the new desk's windows a moment late.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        state?.reloadWindows(Self.visibleWindows(), pointer: Self.pointerTopLeft())
                    }
                }
            }
        }

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

    /// Selectable windows on the current desk. Poach's own windows (including these overlays) are excluded by PID.
    private static func visibleWindows() -> [CaptureWindowCandidate] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return CaptureTargetGeometry.selectableWindows(
            CaptureTargetGeometry.candidates(fromWindowInfo: info),
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// The pointer in global top-left coordinates.
    private static func pointerTopLeft() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    private func finish(_ result: Result<CaptureTarget, Error>) {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        switch result {
        case .failure:
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "Poach" })?.makeKeyAndOrderFront(nil)
        case .success:
            // Hand the keyboard and active appearance back to the app being captured,
            // so the countdown can be used to prepare it and screenshots look active.
            NSApp.deactivate()
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
    private(set) var windows: [CaptureWindowCandidate]
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

    /// Replaces the window list after a desk switch. A target from the previous desk is dropped.
    func reloadWindows(_ windows: [CaptureWindowCandidate], pointer: CGPoint) {
        self.windows = windows
        windowLocked = false
        windowTarget = CaptureTargetGeometry.window(at: pointer, in: windows)
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
        defer {
            if let targetName { AccessibilityNotification.Announcement(targetName).post() }
        }
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

    /// Overlay controls (such as the countdown ✕) must work on the first click even
    /// while another app is frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    @State private var dragging = false

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
                .accessibilityHint(state.mode == .selectedPortion ? "Drag to select an area. The capture controls appear below it." : "Press Tab to choose the next target")

                if state.mode == .selectedPortion {
                    // Only once an area is chosen, attached to its outline.
                    if let area = dragSelection, canStart, !dragging {
                        let frame = CaptureTargetGeometry.attachedPillFrame(
                            for: area, pillSize: CapturePillLayout.size,
                            in: CGRect(origin: .zero, size: geometry.size))
                        pill
                            .overlay { Capsule().strokeBorder(.white, lineWidth: 2).allowsHitTesting(false) }
                            .position(x: frame.midX, y: frame.midY)
                            .transition(.opacity)
                    }
                } else {
                    pill
                        .padding(.bottom, CapturePillLayout.bottomInset)
                        .frame(maxWidth: .infinity)
                }
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

    private var pill: some View {
        CapturePill(
            phase: .selecting(canStart: canStart),
            screenshot: state.screenshot,
            timerExpanded: $state.timerExpanded,
            onPrimary: start,
            onCancel: state.cancel
        )
    }

    private func selectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.mode == .selectedPortion else { return }
                dragging = true
                state.timerExpanded = false
                origin = clamped(value.startLocation, to: size)
                current = clamped(value.location, to: size)
            }
            .onEnded { _ in
                // Displays and windows are picked by pointing; an area shows its pill once the drag ends.
                guard state.mode == .selectedPortion else { return state.point(at: displayID) }
                withAnimation(.easeOut(duration: 0.15)) { dragging = false }
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
