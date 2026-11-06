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
    @State private var hotKeyAvailable = true
    @NSApplicationDelegateAdaptor(PoachAppDelegate.self) private var appDelegate
    private var hudWindow: FloatingHUDWindowController { appDelegate.editor }
    @State private var recordingWindow = RecordingStatusWindowController()
    @State private var captureServiceStorage: AnyObject?
    @State private var captureMode = PoachCaptureMode(rawValue: UserDefaults.standard.string(forKey: "defaultCaptureMode") ?? "") ?? .selectedPortion
    @AppStorage("defaultCaptureMode") private var defaultMode = PoachCaptureMode.selectedPortion.rawValue
    @State private var isWorking = false
    @State private var workingTitle = "Preparing your capture…"
    @State private var isRecording = false
    @State private var loadingFile: URL?
    @StateObject private var importStatus = InspectionStatus()
    @State private var elapsedSeconds = 0

    var body: some Scene {
        Window("Poach", id: "main") {
            PoachHomeView(
                icon: appDelegate.icon,
                isWorking: isWorking,
                workingTitle: workingTitle,
                isRecording: isRecording,
                elapsedSeconds: elapsedSeconds,
                captureMode: $captureMode,
                onStartRecording: startRecording,
                onStopRecording: { Task { await stopRecording() } },
                onLoadMedia: loadMedia,
                onDropMedia: loadMedia(at:),
                loadingFile: loadingFile, status: importStatus
            )
            .background(HomeWindowAnchor())
            .onChange(of: defaultMode) { captureMode = PoachCaptureMode(rawValue: defaultMode) ?? .selectedPortion }
            .onAppear {
                hotKeyAvailable = captureHotKey.register {
                    if isRecording { Task { await stopRecording() } }
                    else if !isWorking {
                        captureMode = .selectedPortion
                        startRecording()
                    }
                }
            }
        }
        .defaultSize(width: 440, height: 278)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Label("Poach", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Button(isRecording ? "Stop and inspect" : "Start recording") {
                    if isRecording { Task { await stopRecording() } }
                    else { startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Text(hotKeyAvailable ? "⌘⇧P — Select area or stop recording" : "⌘⇧P is unavailable. Use the recording button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Load video or image…", action: loadMedia)
                    .buttonStyle(.plain)
                    .disabled(isWorking || isRecording)
            }
            .padding(16)
            .frame(width: 240)
            .preferredColorScheme(.light)
        } label: {
            PoachPouchShape()
                .fill(.primary)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Poach")
        }
        .menuBarExtraStyle(.window)
    }

    private func loadMedia() {
        let picker = NSOpenPanel()
        picker.title = "Load a video or image"
        picker.prompt = "Load"
        picker.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .png, .jpeg, .tiff, .webP, .bmp]
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
        importStatus.begin("Opening file…")
        loadingFile = mediaURL
        Task {
            defer { loadingFile = nil; isWorking = false }
            do {
                let result = try await PoachInspectionRunner.inspect(videoURL: mediaURL) { importStatus.steps.append($0) }
                hudWindow.show(result, status: importStatus)
            } catch {
                showError(title: "Poach couldn't load this media", error: error)
            }
        }
    }

    private func startRecording() {
        guard !isWorking, !isRecording else { return }
        Self.captureLog.notice("Capture selection requested")
        workingTitle = "Preparing your capture…"
        isWorking = true
        Task {
            do {
                guard #available(macOS 15.0, *) else { throw ScreenCaptureError.requiresNewerMacOS }
                let service = ScreenCaptureService()
                captureServiceStorage = service
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
                hudWindow.preparation.steps.append(stage)
            }
            result.pointerTrace = recording.pointerTrace
            Self.captureLog.notice("Recording analysis completed")
            hudWindow.show(result, status: hudWindow.preparation, original: videoURL)
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

    private func showCaptureStartError(_ error: Error) {
        let nsError = error as NSError
        let isPermissionDenied: Bool
        if let captureError = error as? ScreenCaptureError, case .permissionDenied = captureError {
            isPermissionDenied = true
        } else {
            isPermissionDenied = nsError.domain == SCStreamError.errorDomain
                && nsError.code == SCStreamError.Code.userDeclined.rawValue
        }
        guard isPermissionDenied else {
            showError(title: "Poach couldn't start recording", error: error)
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
        pinToEdge(countdownPanel)
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
        pinToEdge(panel)
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
        panel.isMovable = false
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

@MainActor
private final class PoachAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var icon: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !editor.revealEditor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        editor.hideHomeWhileEditing()
    }
}

@MainActor
private final class FloatingHUDWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

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
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return true }

        returningToCapture = true
        pinToEdge(home)
        home.animationBehavior = .none
        let destination = home.frame
        guard let content = sender.contentView, let captureContent = home.contentView,
              let editorImage = snapshot(content), let captureImage = snapshot(captureContent) else {
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
        let alignLeft = UserDefaults.standard.string(forKey: "windowEdge") == "left"
        for view in [capture, editor] {
            view.setFrameOrigin(NSPoint(x: alignLeft ? 0 : surface.bounds.maxX - view.frame.width,
                                        y: surface.bounds.maxY - view.frame.height))
            view.autoresizingMask = [alignLeft ? .maxXMargin : .minXMargin, .minYMargin]
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

    private func snapshot(_ view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        returningToCapture = false
        CaptureStorage.openPaths = []
        panel = nil
        NSApp.windows.first { $0.title == "Poach" }?.makeKeyAndOrderFront(nil)
    }

    func showPreparing() {
        preparation.begin("Opening recording…")
        let panel = self.panel ?? makePanel()
        panel.title = "Poach — Preparing your brief"
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                Text("Preparing your capture for review").font(.headline)
                InspectionStatusLabel(status: preparation)
            }
            .frame(width: 660, height: 500)
            .background(PoachPalette.canvas)
            .preferredColorScheme(.light)
        )
        panel.setContentSize(NSSize(width: 660, height: 500))
        pinToEdge(panel)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismissPreparing() {
        guard panel?.title == "Poach — Preparing your brief" else { return }
        panel?.close()
    }

    func show(_ result: PoachInspection, status: InspectionStatus, original: URL? = nil) {
        CaptureStorage.openPaths = [result.sourcePath] + result.keyframes.map(\.imagePath) + [original?.path].compactMap { $0 }
        status.finish()
        let palette = result.palette.map { HUDPaletteToken(hex: $0, color: Color(hex: $0)) }
        let view = FloatingHUDView(
            sourceURL: URL(fileURLWithPath: result.sourcePath),
            isVideo: result.mediaType != "image",
            status: status,
            palette: palette,
            pointerTrace: result.pointerTrace,
            onShareContext: { try Self.shareContext(result, context: $0, annotations: $1) },
            onClose: { [weak self] in
                self?.panel?.performClose(nil)
            }
        )

        let panel = self.panel ?? makePanel()
        panel.title = "Poach — Implementation brief"
        panel.contentView = NSHostingView(rootView: view.id(UUID()))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 340, height: 370))
        pinToEdge(panel)
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
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func shareContext(_ result: PoachInspection, context: String,
                                    annotations: [InteractionAnnotation]) throws -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Poach", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var evidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] ?? [:]
        evidence["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations))
        let identifier = UUID().uuidString
        let brief: [String: Any] = [
            "briefId": identifier,
            "version": 1,
            "sharedAt": Date().timeIntervalSince1970,
            "context": context,
            "instruction": "Recreate this UI in the current project. Inspect the keyframes, preserve observed behavior and colors, and treat timing estimates as approximate. Ask about ambiguous behavior.",
            "evidence": evidence
        ]
        let destination = directory.appendingPathComponent("active-brief.json")
        try JSONSerialization.data(withJSONObject: brief, options: [.sortedKeys]).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return identifier
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

@MainActor
func pinToEdge(_ window: NSWindow) {
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    window.isMovable = false
    let left = UserDefaults.standard.string(forKey: "windowEdge") == "left"
    window.setFrameOrigin(NSPoint(x: left ? visible.minX + 16 : max(visible.minX, visible.maxX - window.frame.width - 16),
                                  y: max(visible.minY, visible.midY - window.frame.height / 2)))
}

private struct HomeWindowAnchor: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for event in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                          NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(realign),
                                                       name: event, object: window)
            }
            realign()
        }

        @objc private func realign() {
            guard let window else { return }
            DispatchQueue.main.async { pinToEdge(window) }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
}
