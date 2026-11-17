import AppKit
import Carbon
import SwiftUI

/// Runs the optional pre-capture countdown without blocking the screen.
///
/// The overlay only draws the chosen target's outline and the countdown number and lets
/// every click through, so people can prepare the screen (open a menu, hover something).
/// Cancelling uses a small clickable ✕, the ⌘⇧P shortcut (wired by the app), or Esc,
/// which is registered globally only while the countdown runs.
@MainActor
final class CaptureCountdownController {
    static let shared = CaptureCountdownController()

    private(set) var isRunning = false
    private var cancelled = false
    private let escape = PoachHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, id: 2)

    /// - Parameters:
    ///   - outline: the capture target in AppKit global coordinates.
    ///   - screen: the screen that shows the countdown.
    ///   - attachPill: keep the pill next to the outline, where the area selection showed it.
    /// - Throws: `ScreenCaptureError.selectionCancelled` when cancelled.
    func run(seconds: Int, outline: CGRect, on screen: NSScreen, screenshot: Bool = false,
             attachPill: Bool = false) async throws {
        guard seconds > 0, !isRunning else { return }
        isRunning = true
        cancelled = false
        let model = CaptureCountdownModel(count: seconds)
        let overlay = makeOverlay(screen: screen, outline: outline, model: model)
        let pillFrame = attachPill ? CapturePillLayout.panelFrame(attachedTo: outline, on: screen)
            : CapturePillLayout.panelFrame(on: screen)
        let cancelPanel = makePillPanel(frame: pillFrame, screenshot: screenshot)
        _ = escape.register { [weak self] in self?.cancel() }
        defer {
            escape.unregister()
            overlay.orderOut(nil)
            cancelPanel.orderOut(nil)
            isRunning = false
        }
        overlay.orderFrontRegardless()
        cancelPanel.orderFrontRegardless()

        for count in stride(from: seconds, through: 1, by: -1) {
            model.count = count
            // Check often so a cancel feels immediate.
            for _ in 0..<10 {
                if cancelled { throw ScreenCaptureError.selectionCancelled }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    throw ScreenCaptureError.selectionCancelled
                }
            }
        }
        if cancelled { throw ScreenCaptureError.selectionCancelled }
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
    }

    private func makeOverlay(screen: NSScreen, outline: CGRect, model: CaptureCountdownModel) -> NSPanel {
        let panel = CountdownPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Poach — Countdown"
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = false
        let local = CGRect(
            x: outline.minX - screen.frame.minX,
            y: screen.frame.maxY - outline.maxY,
            width: outline.width,
            height: outline.height
        )
        panel.contentView = TransparentHostingView(rootView: CaptureCountdownOverlayView(model: model, outline: local))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.setFrame(screen.frame, display: true)
        return panel
    }

    /// The capture pill in its countdown state: only ✕ is active.
    private func makePillPanel(frame: CGRect, screenshot: Bool) -> NSPanel {
        let panel = CountdownPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Poach — Cancel countdown"
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = TransparentHostingView(rootView: CapturePill(
            phase: .countdown,
            screenshot: screenshot,
            timerExpanded: .constant(false),
            onPrimary: {},
            onCancel: { [weak self] in self?.cancel() }
        ))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.setFrame(frame, display: true)
        return panel
    }
}

@MainActor
private final class CaptureCountdownModel: ObservableObject {
    @Published var count: Int
    init(count: Int) { self.count = count }
}

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private struct CaptureCountdownOverlayView: View {
    @ObservedObject var model: CaptureCountdownModel
    let outline: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(.black.opacity(0.35), lineWidth: 3)
                .overlay { Rectangle().strokeBorder(.white, lineWidth: 2) }
                .frame(width: outline.width, height: outline.height)
                .offset(x: outline.minX, y: outline.minY)
            PoachCountdown(count: model.count)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.count)
                .position(x: outline.midX, y: outline.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .preferredColorScheme(.light)
    }
}
