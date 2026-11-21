import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import OSLog
import ScreenCaptureKit

@main
struct PoachApp: App {
    private static let captureLog = Logger(subsystem: "dev.poach.app", category: "CaptureLifecycle")
    @State private var captureHotKey = PoachHotKey()
    @NSApplicationDelegateAdaptor(PoachAppDelegate.self) private var appDelegate
    private var hudWindow: FloatingHUDWindowController { appDelegate.editor }
    @State private var recordingWindow = RecordingStatusWindowController()
    @State private var captureServiceStorage: AnyObject?
    @State private var captureMode = PoachCaptureMode(rawValue: UserDefaults.standard.string(forKey: "defaultCaptureMode") ?? "") ?? .selectedPortion
    @State private var captureType = PoachCaptureType.record
    @State private var homeTab = PoachHomeView.Tab.capture
    @State private var handledChromeCaptureRequest = 0
    @AppStorage("defaultCaptureMode") private var defaultMode = PoachCaptureMode.selectedPortion.rawValue
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var shouldShowOnboarding = !UserDefaults.standard.bool(forKey: "hasShownOnboarding")
        && !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var isMinimizingOnboarding = false
    @State private var pendingOnboardingAnimation: (() -> Void)?
    @State private var isWorking = false
    @State private var isChoosingCaptureSource = false
    @State private var workingTitle = "Preparing your capture…"
    @State private var isRecording = false
    @State private var loadingFile: URL?
    @StateObject private var importStatus = InspectionStatus()
    @State private var isCheckingForUpdates = false
    @State private var elapsedSeconds = 0

    var body: some Scene {
        Window("Poach", id: "main") {
            mainWindow
        }
        .defaultSize(width: 440, height: 278)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: checkForUpdates)
                    .disabled(isWorking || isRecording || isCheckingForUpdates)
            }
        }

        MenuBarExtra {
            PoachStatusMenu(
                editor: hudWindow,
                isWorking: isWorking,
                isRecording: isRecording,
                onSelectCaptureType: { type in
                    captureType = type
                    homeTab = .capture
                },
                canCheckForUpdates: !isWorking && !isRecording && !isCheckingForUpdates,
                onCheckForUpdates: checkForUpdates,
                onStopRecording: { Task { await stopRecording() } }
            )
        } label: {
            Image(nsImage: PoachPouchShape.menuBarIcon)
                .accessibilityLabel("Poach")
        }
        .menuBarExtraStyle(.menu)
    }

    private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task {
            defer { isCheckingForUpdates = false }
            await PoachUpdates.check()
        }
    }

    @ViewBuilder
    private var mainWindow: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--poach-design-lab") {
            PoachDesignLab()
        } else {
            captureWindow
        }
        #else
        captureWindow
        #endif
    }

    private var captureWindow: some View {
        ZStack {
            if !shouldShowOnboarding || isMinimizingOnboarding {
                PoachHomeView(
                    icon: appDelegate.icon,
                    isWorking: isWorking,
                    workingTitle: workingTitle,
                    isRecording: isRecording,
                    elapsedSeconds: elapsedSeconds,
                    captureMode: $captureMode,
                    captureType: $captureType,
                    tab: $homeTab,
                    onStartRecording: startRecording,
                    onScreenshot: takeScreenshot,
                    onCancelSelection: cancelSelectionAction,
                    onStopRecording: { Task { await stopRecording() } },
                    onLoadMedia: loadMedia,
                    onDropMedia: loadMedia(at:),
                    loadingFile: loadingFile, status: importStatus
                )
                .background(HomeWindowAnchor(onAttach: pendingOnboardingAnimation))
                .onChange(of: defaultMode) { captureMode = PoachCaptureMode(rawValue: defaultMode) ?? .selectedPortion }
                .onAppear {
                    _ = captureHotKey.register {
                        if isRecording { Task { await stopRecording() } }
                        else if !isWorking {
                            captureMode = .selectedPortion
                            startRecording()
                        }
                    }
                }
            }
            if shouldShowOnboarding {
                PoachOnboardingView(onContinue: finishOnboarding)
                .background(HomeWindowAnchor(shouldCenter: { !isMinimizingOnboarding }))
                .opacity(isMinimizingOnboarding ? 0 : 1)
                .allowsHitTesting(!isMinimizingOnboarding)
                .accessibilityHidden(isMinimizingOnboarding)
                .onAppear { hasShownOnboarding = true }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                    guard let window = notification.object as? NSWindow, window.title == "Poach" else { return }
                    // Keep the welcome content in place until AppKit finishes closing it.
                    DispatchQueue.main.async { shouldShowOnboarding = false }
                }
            }
        }
        .onChange(of: PoachChromeBridge.shared.captureRequest, initial: true) { _, request in
            guard request != handledChromeCaptureRequest else { return }
            handledChromeCaptureRequest = request
            homeTab = .capture
            if shouldShowOnboarding {
                hasShownOnboarding = true
                shouldShowOnboarding = false
            }
        }
    }

    private func finishOnboarding() {
        guard !isMinimizingOnboarding else { return }
        guard let window = NSApp.keyWindow, window.title == "Poach" else {
            shouldShowOnboarding = false
            return
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let content = window.contentView, let image = windowSnapshot(content),
              let screen = window.screen ?? NSScreen.main else {
            shouldShowOnboarding = false
            return
        }

        let preview = NSImageView(frame: content.bounds)
        preview.image = image
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.autoresizingMask = [.width, .height]
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(PoachPalette.canvas).cgColor
        content.addSubview(preview, positioned: .above, relativeTo: nil)

        let homeRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: PoachHomeView.windowSize))
        let destination = fitWindowFrame(
            NSRect(x: window.frame.midX - homeRect.width / 2, y: window.frame.midY - homeRect.height / 2,
                   width: homeRect.width, height: homeRect.height),
            in: screen.visibleFrame
        )
        pendingOnboardingAnimation = {
            pendingOnboardingAnimation = nil
            content.layoutSubtreeIfNeeded()
            window.contentMinSize = PoachHomeView.windowSize
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.30
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(destination, display: true)
                preview.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    preview.removeFromSuperview()
                    shouldShowOnboarding = false
                    isMinimizingOnboarding = false
                }
            }
        }
        // Mount Capture under the snapshot before starting the window animation.
        isMinimizingOnboarding = true
    }

    private func loadMedia() {
        let picker = NSOpenPanel()
        picker.title = "Load a video or image"
        picker.prompt = "Load"
        picker.allowedContentTypes = PoachImportMedia.contentTypes
        picker.allowsOtherFileTypes = false
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        guard picker.runModal() == .OK, let mediaURL = picker.url else { return }

        loadMedia(at: mediaURL)
    }

    private func loadMedia(at mediaURL: URL) {
        guard !isWorking, !isRecording, mediaURL.isFileURL else { return }
        workingTitle = "Opening file…"
        isWorking = true
        let isImage = PoachImportMedia.isImage(mediaURL)
        importStatus.begin("Opening file", stages: isImage ? InspectionStage.stillImage : InspectionStage.allCases)
        loadingFile = mediaURL
        Task {
            defer { loadingFile = nil; isWorking = false }
            do {
                let result = try await PoachInspectionRunner.inspect(videoURL: mediaURL) { importStatus.advance(to: $0) }
                hudWindow.show(result)
            } catch {
                showError(title: "Poach couldn't load this media", error: error)
            }
        }
    }

    private func takeScreenshot() {
        guard !isWorking, !isRecording else { return }
        workingTitle = "Preparing screenshot…"
        isWorking = true
        Task {
            defer { isWorking = false; captureServiceStorage = nil }
            do {
                guard #available(macOS 15.0, *) else { throw ScreenCaptureError.screenshotRequiresNewerMacOS }
                let screenshot = try await makeCaptureService().captureScreenshot(mode: captureMode)
                hudWindow.showPreparing("Opening screenshot", stages: InspectionStage.stillImage)
                var result = try await PoachInspectionRunner.inspect(videoURL: screenshot.url) { stage in
                    hudWindow.preparation.advance(to: stage)
                }
                if screenshot.sizePoints.width > 0, screenshot.sizePoints.height > 0 {
                    result.capture?.deviceScale = Double(result.capture?.widthPx ?? 0) / screenshot.sizePoints.width
                    result.capture?.widthPoints = screenshot.sizePoints.width
                    result.capture?.heightPoints = screenshot.sizePoints.height
                }
                hudWindow.show(
                    result,
                    original: screenshot.url,
                    captureEpochRange: screenshot.capturedAtEpochMs...screenshot.capturedAtEpochMs
                )
            } catch {
                hudWindow.dismissPreparing()
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title == "Poach" }?.makeKeyAndOrderFront(nil)
                if (error as? ScreenCaptureError)?.isUserCancelled != true {
                    showCaptureStartError(error, title: "Poach couldn't take this screenshot")
                }
            }
        }
    }

    @available(macOS 15.0, *)
    private func makeCaptureService() -> ScreenCaptureService {
        let service = ScreenCaptureService()
        service.onPickerStateChange = { isChoosingCaptureSource = $0 }
        captureServiceStorage = service
        return service
    }

    private func cancelPickerSelection() {
        if #available(macOS 15.0, *) {
            (captureServiceStorage as? ScreenCaptureService)?.cancelPickerSelection()
        }
    }

    private var cancelSelectionAction: (() -> Void)? {
        guard isChoosingCaptureSource else { return nil }
        return { cancelPickerSelection() }
    }

    private func startRecording() {
        guard !isWorking, !isRecording else { return }
        Self.captureLog.notice("Capture selection requested")
        workingTitle = "Preparing your capture…"
        isWorking = true
        Task {
            do {
                guard #available(macOS 15.0, *) else { throw ScreenCaptureError.requiresNewerMacOS }
                let service = makeCaptureService()
                try await service.startRecording(mode: captureMode) {
                    try await recordingWindow.countDown()
                }

                NSApp.unhide(nil)
                NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
                service.showRecordingAreaShadow()
                isWorking = false
                isRecording = true
                Self.captureLog.notice("Recording started")
                elapsedSeconds = 0
                recordingWindow.show(elapsedSeconds: 0) { Task { await stopRecording() } }

                while isRecording && elapsedSeconds < 30 {
                    try? await Task.sleep(for: .seconds(1))
                    guard isRecording else { break }
                    elapsedSeconds += 1
                    recordingWindow.update(elapsedSeconds: elapsedSeconds)
                }
                if isRecording { await stopRecording() }
            } catch {
                if let captureError = error as? ScreenCaptureError, captureError.isUserCancelled {
                    Self.captureLog.notice("Capture selection cancelled")
                    isWorking = false
                    captureServiceStorage = nil
                    NSApp.unhide(nil)
                    NSApp.windows.first { $0.title == "Poach" }?.makeKeyAndOrderFront(nil)
                    return
                }
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                Self.captureLog.error("Capture start failed: code \((error as NSError).code)")
                showCaptureStartError(error)
                isWorking = false
                captureServiceStorage = nil
            }
        }
    }

    private func stopRecording() async {
        guard #available(macOS 15.0, *) else { return }
        guard isRecording, let service = captureServiceStorage as? ScreenCaptureService else { return }
        Self.captureLog.notice("Recording stop requested")
        isRecording = false
        workingTitle = "Analyzing your recording…"
        isWorking = true
        recordingWindow.showFinishing()
        do {
            let recording = try await service.stopRecording()
            let videoURL = recording.url
            Self.captureLog.notice("Recording file finalized")
            captureServiceStorage = nil
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            hudWindow.showPreparing()
            recordingWindow.close()
            var result = try await PoachInspectionRunner.inspect(videoURL: videoURL, isRecording: true) { stage in
                hudWindow.preparation.advance(to: stage)
            }
            result.pointerTrace = recording.pointerTrace
            if recording.sizePoints.width > 0, recording.sizePoints.height > 0 {
                result.capture?.deviceScale = Double(result.capture?.widthPx ?? 0) / recording.sizePoints.width
                result.capture?.widthPoints = recording.sizePoints.width
                result.capture?.heightPoints = recording.sizePoints.height
            }
            Self.captureLog.notice("Recording analysis completed")
            hudWindow.show(result, original: videoURL, captureEpochRange: recording.epochRange)
            Self.captureLog.notice("Review editor presented")
        } catch {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            recordingWindow.close()
            Self.captureLog.error("Capture processing failed: code \((error as NSError).code)")
            showError(title: "Poach couldn't finish this capture", error: error)
            captureServiceStorage = nil
        }
        isWorking = false
    }

    private func showError(title: String, error: Error) {
        hudWindow.dismissPreparing()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCaptureStartError(_ error: Error, title: String = "Poach couldn't start recording") {
        let nsError = error as NSError
        let isPermissionDenied: Bool
        if let captureError = error as? ScreenCaptureError, case .permissionDenied = captureError {
            isPermissionDenied = true
        } else {
            isPermissionDenied = nsError.domain == SCStreamError.errorDomain
                && nsError.code == SCStreamError.Code.userDeclined.rawValue
        }
        guard isPermissionDenied else {
            showError(title: title, error: error)
            return
        }

        let permissionPreflightPassed = CGPreflightScreenCaptureAccess()
        Self.captureLog.error(
            "Screen capture denied; permission preflight \(permissionPreflightPassed ? "passed" : "failed", privacy: .public), domain \(nsError.domain, privacy: .public), code \(nsError.code, privacy: .public)"
        )
        let alert = NSAlert()
        alert.messageText = permissionPreflightPassed
            ? "Poach couldn't start this capture"
            : "Poach couldn't access the screen"
        alert.informativeText = permissionPreflightPassed
            ? "macOS reports Screen Recording access for Poach, but ScreenCaptureKit refused this request. Quit and reopen Poach, then try again. If the problem continues, this signed copy may not match the app identity macOS approved."
            : "macOS refused the ScreenCaptureKit request. Quit and reopen Poach first, then try again. If capture still fails, check that this exact copy of Poach is enabled in Screen & System Audio Recording. Rebuilt or differently signed copies can appear as separate apps."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

private extension ScreenCaptureError {
    var isUserCancelled: Bool {
        if case .selectionCancelled = self { return true }
        return false
    }
}

@MainActor
private final class RecordingStatusWindowController {
    private var panel: NSPanel?
    private var stopAction: (() -> Void)?

    func countDown() async throws {
        var cancelled = false
        let countdownPanel = makePanel()
        countdownPanel.setContentSize(NSSize(width: 120, height: 120))
        positionWindow(countdownPanel, near: NSApp.windows.first { $0.title == "Poach" })
        NSApp.unhide(nil)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        defer { countdownPanel.orderOut(nil) }
        for count in stride(from: 3, through: 1, by: -1) {
            countdownPanel.contentView = NSHostingView(rootView:
                Button { cancelled = true } label: { PoachCountdown(count: count) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Cancel recording")
                    .help("Cancel countdown")
                .preferredColorScheme(.light)
            )
            countdownPanel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1))
            if cancelled { throw ScreenCaptureError.selectionCancelled }
        }
    }

    func show(elapsedSeconds: Int, onStop: @escaping () -> Void) {
        stopAction = onStop
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: PoachRecordingStatusView(elapsedSeconds: elapsedSeconds) { [weak self] in
            self?.stopAction?()
        })
        if self.panel == nil, let visible = (NSApp.windows.first { $0.title == "Poach" }?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16,
                                         y: visible.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(elapsedSeconds: Int) {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: PoachRecordingStatusView(elapsedSeconds: elapsedSeconds) { [weak self] in
            self?.stopAction?()
        })
    }

    func showFinishing() {
        stopAction = nil
        panel?.contentView = NSHostingView(rootView:
            HStack {
                ProgressView().controlSize(.small)
                Text("Finishing recording…")
            }
            .frame(width: 260, height: 58)
            .background(PoachPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
            .preferredColorScheme(.light)
        )
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        stopAction = nil
    }

    private func makePanel() -> NSPanel {
        let panel = EditableBriefPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct PoachStatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var editor: FloatingHUDWindowController
    let isWorking: Bool
    let isRecording: Bool
    let onSelectCaptureType: (PoachCaptureType) -> Void
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void
    let onStopRecording: () -> Void

    var body: some View {
        Button("Open Poach", action: showPoach)
            .disabled(isRecording)

        Divider()

        Button("New Screenshot") { prepareCapture(.screenshot) }
            .disabled(captureUnavailable)
        Button("New Recording") { prepareCapture(.record) }
            .disabled(captureUnavailable)
        if isRecording {
            Button("Stop Recording", action: onStopRecording)
        }

        Divider()

        Button("Check for Updates…", action: onCheckForUpdates)
            .disabled(!canCheckForUpdates)

        Button("Quit Poach") { NSApp.terminate(nil) }
            .disabled(isWorking || isRecording)
    }

    private var captureUnavailable: Bool {
        isWorking || isRecording || editor.hasOpenEditor
    }

    private func showPoach() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !editor.revealEditor() {
            openWindow(id: "main")
        }
    }

    private func prepareCapture(_ type: PoachCaptureType) {
        guard !captureUnavailable else { return }
        onSelectCaptureType(type)
        showPoach()
    }
}

@MainActor
private final class PoachAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var icon: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PoachChromeBridge.shared.openCapture = {
            NSApp.unhide(nil)
            if let window = NSApp.windows.first(where: { $0.title == "Poach" && $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return true
            }
            return NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        PoachChromeBridge.shared.startIfPaired()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
            Task { @MainActor [weak self] in self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        // A compiled layered icon is rendered by macOS, including Dock tint and clear styles.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil {
            icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            return
        }
        guard let url = Bundle.main.url(forResource: "Pouch", withExtension: "png"),
              let pouch = NSImage(contentsOf: url) else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let paper = NSColor(srgbRed: 247/255, green: 247/255, blue: 245/255, alpha: 1)
        let tile = dark ? NSColor(srgbRed: 0.147, green: 0.147, blue: 0.153, alpha: 1) : paper
        let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            tile.setFill()
            NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                         xRadius: 190, yRadius: 190).fill()
            pouch.draw(in: NSRect(x: 220, y: 220, width: 584, height: 584))
            return true
        }
        NSApp.applicationIconImage = image
        icon = image
    }

    let editor = FloatingHUDWindowController()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !editor.revealEditor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        editor.hideHomeWhileEditing()
    }
}

@MainActor
private final class FloatingHUDWindowController: NSObject, NSWindowDelegate, ObservableObject {
    @Published private var panel: NSPanel?
    var hasOpenEditor: Bool { panel != nil }

    let preparation = InspectionStatus()
    private var returningToCapture = false

    func hideHomeWhileEditing() {
        guard panel != nil, !returningToCapture else { return }
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
    }

    func revealEditor() -> Bool {
        guard let panel else { return false }
        if returningToCapture { return true }
        hideHomeWhileEditing()
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel, sender.title == "Poach — Implementation brief",
              let home = NSApp.windows.first(where: { $0.title == "Poach" }) else { return true }
        guard !returningToCapture else { return false }
        let destination = positionedFrame(for: home, near: sender)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            home.setFrame(destination, display: false)
            return true
        }

        returningToCapture = true
        home.animationBehavior = .none
        guard let content = sender.contentView, let captureContent = home.contentView,
              let editorImage = windowSnapshot(content), let captureImage = windowSnapshot(captureContent) else {
            returningToCapture = false
            return true
        }

        // Use a single surface while resizing. Both layouts keep their native text size.
        let surface = NSView(frame: content.bounds)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(PoachPalette.canvas).cgColor
        surface.layer?.masksToBounds = true
        let capture = NSImageView(image: captureImage)
        let editor = NSImageView(image: editorImage)
        for view in [capture, editor] {
            view.setFrameOrigin(NSPoint(x: 0, y: surface.bounds.maxY - view.frame.height))
            view.autoresizingMask = [.maxXMargin, .minYMargin]
            surface.addSubview(view)
        }
        sender.contentView = surface
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sender.animator().setFrame(destination, display: true)
            editor.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender, self.panel === sender else { return }
                // Put the live view underneath its matching last frame before retiring the panel.
                home.setFrame(destination, display: true)
                home.order(.below, relativeTo: sender.windowNumber)
                home.displayIfNeeded()
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        returningToCapture = false
        CaptureStorage.openPaths = []
        panel = nil
        NSApp.windows.first { $0.title == "Poach" }?.makeKeyAndOrderFront(nil)
    }

    func showPreparing(_ title: String = "Opening recording", stages: [InspectionStage] = InspectionStage.allCases) {
        preparation.begin(title, stages: stages)
        let panel = self.panel ?? makePanel()
        panel.title = "Poach — Preparing your brief"
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                Text("Preparing your capture for review").font(.headline)
                InspectionStatusLabel(status: preparation).frame(width: 360)
            }
            .frame(width: 660, height: 500)
            .background(PoachPalette.canvas)
            .preferredColorScheme(.light)
        )
        panel.setContentSize(NSSize(width: 660, height: 500))
        positionWindow(panel, near: NSApp.windows.first { $0.title == "Poach" })
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismissPreparing() {
        guard panel?.title == "Poach — Preparing your brief" else { return }
        panel?.close()
    }

    func show(_ result: PoachInspection, original: URL? = nil, captureEpochRange: ClosedRange<Int>? = nil) {
        CaptureStorage.openPaths = [result.sourcePath] + result.keyframes.map(\.imagePath) + [original?.path].compactMap { $0 }
        let palette = result.palette.map { HUDPaletteToken(hex: $0, color: Color(hex: $0)) }
        let panel = self.panel ?? makePanel()
        let anchor = self.panel ?? NSApp.windows.first { $0.title == "Poach" }
        let anchorFrame = anchor?.frame
        let screen = anchor?.screen ?? NSScreen.main
        let visibleSize = screen?.visibleFrame.size ?? CGSize(width: 800, height: 800)
        let contentHeight = panel.contentRect(forFrameRect: CGRect(origin: .zero, size: visibleSize)).height
        let view = FloatingHUDView(
            sourceURL: URL(fileURLWithPath: result.sourcePath),
            isVideo: result.mediaType != "image",
            availableWidth: visibleSize.width - 32,
            availableHeight: contentHeight - 32,
            palette: palette,
            pointerTrace: result.pointerTrace,
            captureEpochRange: captureEpochRange,
            onShareContext: { context, annotations, browserEvidence, fontMatch in
                var handoff = result
                handoff.browserEvidence = browserEvidence
                handoff.visualFontMatch = fontMatch
                return try PoachHandoff.share(handoff, context: context, annotations: annotations)
            },
            onSaveFavorite: { name, context, annotations, browserEvidence, fontMatch in
                var handoff = result
                handoff.browserEvidence = browserEvidence
                handoff.visualFontMatch = fontMatch
                return try PoachFavoriteStore.save(name: name, result: handoff, context: context, annotations: annotations)
            },
            onClose: { [weak self] in
                self?.panel?.performClose(nil)
            }
        )

        panel.title = "Poach — Implementation brief"
        panel.contentView = NSHostingView(rootView: view.id(UUID()))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 340, height: 370))
        if let anchorFrame, let visible = screen?.visibleFrame {
            var frame = panel.frame
            frame.origin = NSPoint(x: anchorFrame.minX, y: anchorFrame.maxY - frame.height)
            panel.setFrame(fitWindowFrame(frame, in: visible), display: false)
        } else {
            panel.center()
        }
        panel.alphaValue = 0
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    private func makePanel() -> NSPanel {
        let panel = EditableBriefPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.isOpaque = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(PoachPalette.canvas)
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }


}

private final class EditableBriefPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

func fitWindowFrame(_ frame: NSRect, in visible: NSRect) -> NSRect {
    var fitted = frame
    fitted.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
    fitted.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
    return fitted
}

@MainActor
private func positionedFrame(for window: NSWindow, near anchor: NSWindow?) -> NSRect {
    guard let visible = (anchor?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame else { return window.frame }
    var frame = window.frame
    frame.origin = anchor.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY - frame.height) }
        ?? NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
    return fitWindowFrame(frame, in: visible)
}

@MainActor
private func positionWindow(_ window: NSWindow, near anchor: NSWindow?) {
    window.setFrame(positionedFrame(for: window, near: anchor), display: false)
}

@MainActor
private func windowSnapshot(_ view: NSView) -> NSImage? {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(bitmap)
    return image
}

private struct HomeWindowAnchor: NSViewRepresentable {
    var shouldCenter: (() -> Bool)?
    var onAttach: (() -> Void)?

    final class Anchor: NSView {
        var shouldCenter: (() -> Bool)?
        var onAttach: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            if shouldCenter != nil {
                window.titlebarAppearsTransparent = true
                NotificationCenter.default.addObserver(self, selector: #selector(realign),
                                                       name: NSWindow.didResizeNotification, object: window)
            }
            realign()
        }

        @objc private func realign() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if let onAttach = self.onAttach {
                    self.onAttach = nil
                    onAttach()
                    return
                }
                guard self.shouldCenter?() == true,
                      let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                              y: visible.midY - window.frame.height / 2))
            }
        }

    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.shouldCenter = shouldCenter
        anchor.onAttach = onAttach
        return anchor
    }
    func updateNSView(_ view: Anchor, context: Context) {}
}
