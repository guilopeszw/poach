import AppKit
import Carbon
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
}

/// Poach-owned selection for the area and full-screen modes, with the capture pill
/// (timer · capture · close). App windows use `WindowCaptureChooser` instead.
/// Selection never runs the countdown; `CaptureCountdownController` does that afterwards.
@MainActor
final class CaptureSelectionWindowController {
    static let shared = CaptureSelectionWindowController()
    private var panels: [NSPanel] = []
    private var glassBackdrops: [CaptureGlassBackdrop] = []
    private var continuation: CheckedContinuation<CaptureTarget, Error>?
    /// Esc, registered only while the overlay is up. macOS often keeps the previous app
    /// active (for example after ⌘⇧P), so a view-level shortcut would never see the key.
    private let escape = PoachHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 3)

    func select(mode: PoachCaptureMode, screenshot: Bool) async throws -> CaptureTarget {
        precondition(mode != .window, "App windows are chosen with WindowCaptureChooser.")
        NSApp.unhide(nil)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (screen, id)
        }
        guard !screens.isEmpty else { throw ScreenCaptureError.noDisplay }
        let state = CaptureSelectionState(
            mode: mode,
            screenshot: screenshot,
            displays: screens.map { CaptureSelectionState.Display(id: $0.1, name: $0.0.localizedName) }
        )
        state.displayTarget = screens.first { $0.0.frame.contains(NSEvent.mouseLocation) }?.1 ?? screens[0].1
        state.onFinish = { [weak self] result in self?.finish(result) }
        _ = escape.register { [weak state] in
            guard let state else { return }
            if state.timerExpanded { state.timerExpanded = false } else { state.cancel() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for (screen, displayID) in screens {
                let glassBackdrop = CaptureGlassBackdrop()
                glassBackdrops.append(glassBackdrop)
                if mode == .selectedPortion { glassBackdrop.start(displayID: displayID) }
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
                panel.contentView = TransparentHostingView(rootView: CaptureSelectionView(
                    state: state,
                    displayID: displayID
                ).environment(\.captureGlassBackdrop, glassBackdrop))
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
        escape.unregister()
        glassBackdrops.forEach { $0.stop() }
        glassBackdrops.removeAll()
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
    let displays: [Display]
    @Published var displayTarget: CGDirectDisplayID?
    @Published var timerExpanded = false
    var onFinish: (Result<CaptureTarget, Error>) -> Void = { _ in }

    init(mode: PoachCaptureMode, screenshot: Bool, displays: [Display]) {
        self.mode = mode
        self.screenshot = screenshot
        self.displays = displays
    }

    /// Pointer moved over (or clicked) `displayID`: in full-screen mode that display becomes the target.
    func point(at displayID: CGDirectDisplayID) {
        if mode == .fullScreen { displayTarget = displayID }
    }

    func cycle(forward: Bool) {
        defer {
            if let targetName { AccessibilityNotification.Announcement(targetName).post() }
        }
        guard mode == .fullScreen else { return }
        let current = displays.firstIndex { $0.id == displayTarget }
        if let index = CaptureTargetGeometry.cycledIndex(from: current, count: displays.count, forward: forward) {
            displayTarget = displays[index].id
        }
    }

    var targetName: String? {
        mode == .fullScreen ? displays.first { $0.id == displayTarget }?.name : nil
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
        case .fullScreen, .window:
            return nil
        }
    }

    /// macOS 26: a clear glass surface refracts the edges without frosting the selection.
    private static var glassOutline: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    private var isTargetScreen: Bool { state.mode == .fullScreen && state.displayTarget == displayID }

    private var canStart: Bool {
        switch state.mode {
        case .selectedPortion: (dragSelection?.width ?? 0) >= 32 && (dragSelection?.height ?? 0) >= 32
        case .fullScreen: state.displayTarget != nil
        case .window: false
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
                    // The area has the pill's corner radius, so the pill leaving it reads as one shape.
                    var mask = Path(CGRect(origin: .zero, size: size))
                    if let highlight, highlight.width > 3, highlight.height > 3 {
                        mask.addPath(Path(roundedRect: highlight, cornerRadius: CapturePillLayout.areaCornerRadius(for: highlight),
                                          style: .continuous))
                    }
                    context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))
                    // macOS 26 draws the outline as a glass ring instead (below).
                    if let highlight, !Self.glassOutline {
                        let radius = CapturePillLayout.areaCornerRadius(for: highlight)
                        context.stroke(Path(roundedRect: highlight, cornerRadius: radius, style: .continuous),
                                       with: .color(.white), lineWidth: 2)
                        context.stroke(Path(roundedRect: highlight.insetBy(dx: 3, dy: 3), cornerRadius: max(0, radius - 3),
                                            style: .continuous), with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active = phase { state.point(at: displayID) }
                }
                .gesture(selectionGesture(in: geometry.size))
                .accessibilityElement()
                .accessibilityLabel(state.mode == .selectedPortion ? "Capture area" : "Capture target")
                .accessibilityValue(state.targetName ?? "None")
                .accessibilityHint(state.mode == .selectedPortion ? "Drag to select an area. The capture controls appear below it." : "Press Tab to choose the next target")

                if state.mode == .selectedPortion {
                    // The drop-in owns both surfaces after release, so their glass can merge.
                    if #available(macOS 26.0, *), let area = dragSelection, area.width > 3, area.height > 3,
                       !(canStart && !dragging) {
                        CaptureAreaGlass(area: area)
                    }
                    // Only once an area is chosen: a drop falls from its outline and becomes the pill.
                    if let area = dragSelection, canStart, !dragging {
                        let frame = CaptureTargetGeometry.attachedPillFrame(
                            for: area, pillSize: CapturePillLayout.size,
                            in: CGRect(origin: .zero, size: geometry.size))
                        let origin = CaptureTargetGeometry.pillAttachmentPoint(
                            for: area, pillFrame: frame, cornerRadius: CapturePillLayout.areaCornerRadius(for: area))
                        CapturePillDropIn(origin: origin, frame: frame, outline: Self.glassOutline ? area : nil) { opacity in
                            pill(controlsOpacity: opacity)
                        }
                    }
                } else {
                    pill()
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

    private func pill(controlsOpacity: Double = 1) -> some View {
        CapturePill(
            phase: .selecting(canStart: canStart),
            screenshot: state.screenshot,
            timerExpanded: $state.timerExpanded,
            onPrimary: start,
            onCancel: state.cancel,
            controlsOpacity: controlsOpacity
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
                dragging = false
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
            break
        }
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }
}
