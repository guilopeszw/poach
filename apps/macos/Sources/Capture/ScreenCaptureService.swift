import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

enum PoachCaptureMode: String, CaseIterable, Identifiable {
    case selectedPortion
    case fullScreen
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selectedPortion: "Screen area"
        case .fullScreen: "Full screen"
        case .window: "App window"
        }
    }

    var guidance: String {
        switch self {
        case .selectedPortion: "Select an area, then click the red record button. Recording starts after three seconds."
        case .fullScreen: "Choose the display you want to capture."
        case .window: "Choose the app window you want to capture."
        }
    }
}

enum ScreenCaptureError: LocalizedError {
    case requiresNewerMacOS
    case permissionDenied
    case selectionCancelled
    case selectionFailed(String)
    case noDisplay
    case recordingUnavailable
    case notRecording
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .requiresNewerMacOS:
            "Screen recording requires macOS 15 or later. You can still load an existing video or image."
        case .permissionDenied:
            "macOS refused this screen capture request. Quit and reopen Poach first. If it still fails, check that this copy is enabled in Screen & System Audio Recording; macOS can treat rebuilt or differently signed copies as separate apps."
        case .selectionCancelled:
            "Capture selection was cancelled."
        case .selectionFailed(let message): message
        case .noDisplay:
            "Poach couldn't find the selected display. Connect a display and try again."
        case .recordingUnavailable:
            "This Mac doesn't report a compatible screen recording format."
        case .notRecording:
            "There isn't an active recording to stop."
        case .emptyRecording:
            "No video frames were recorded. If Poach is already enabled in Screen & System Audio Recording, quit and reopen Poach. If it still fails, macOS may not recognize this signed copy as the app you approved."
        }
    }
}

struct ScreenCaptureRecording {
    let url: URL
    let pointerTrace: PointerTrace
}

@available(macOS 15.0, *)
@MainActor
final class ScreenCaptureService: NSObject, SCRecordingOutputDelegate, SCContentSharingPickerObserver {
    private var stream: SCStream?
    private var outputURL: URL?
    private var pickerContinuation: CheckedContinuation<ContentFilterBox, Error>?
    private var activePicker: SCContentSharingPicker?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var didFinish = false
    private var recordingError: Error?
    private var pointerTraceRecorder: PointerTraceRecorder?
    private var activeSelectedRegion: SelectedRegion?
    private var recordingAreaShadow: RecordingAreaShadowWindowController?

    func startRecording(mode: PoachCaptureMode, beforeCapture: @MainActor () async throws -> Void) async throws {
        let selectedRegion: SelectedRegion?
        let filter: SCContentFilter
        if mode == .selectedPortion {
            let region = try await RegionSelectionWindowController.shared.selectRegion()
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                if Self.isPermissionDenied(error) { throw ScreenCaptureError.permissionDenied }
                throw error
            }
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw ScreenCaptureError.noDisplay
            }
            let poachApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            guard !poachApplications.isEmpty else { throw ScreenCaptureError.selectionFailed("Poach could not exclude its windows from this display.") }
            filter = SCContentFilter(display: display, excludingApplications: poachApplications, exceptingWindows: [])
            selectedRegion = region
        } else {
            if mode == .window {
                filter = try await chooseContent(for: mode).filter
            } else {
                let display: SCDisplay
                let content: SCShareableContent
                if #available(macOS 15.2, *) {
                    let picked = try await chooseContent(for: mode).filter
                    guard let selected = picked.includedDisplays.first else { throw ScreenCaptureError.noDisplay }
                    display = selected
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                } else {
                    // Older pickers do not expose their selected display for application filtering.
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    display = try chooseDisplay(from: content.displays)
                }
                let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                guard !excluded.isEmpty else { throw ScreenCaptureError.selectionFailed("Poach could not exclude its windows from this display.") }
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            }
            selectedRegion = nil
            try await beforeCapture()
        }
        activeSelectedRegion = selectedRegion
        let selectedRect: CGRect?
        selectedRect = selectedRegion?.rect

        let sourceSize = selectedRect?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let dimensionScale = min(1, 1920 / max(sourceSize.width * scale, sourceSize.height * scale))
        // H.264 encoders expect even dimensions, including arbitrary dragged regions.
        let width = max(2, Int(sourceSize.width * scale * dimensionScale) / 2 * 2)
        let height = max(2, Int(sourceSize.height * scale * dimensionScale) / 2 * 2)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        // Keep both the pointer and Apple's click rings in the recorded pixels. The
        // cursor is part of the interaction being inspected, not just decoration.
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.capturesAudio = false
        if let selectedRect { configuration.sourceRect = selectedRect }

        let directory = FileManager.default.temporaryDirectory.appending(path: "Poach", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "capture-\(UUID().uuidString).mov")
        let recordingConfiguration = SCRecordingOutputConfiguration()
        guard recordingConfiguration.availableOutputFileTypes.contains(.mov) else {
            throw ScreenCaptureError.recordingUnavailable
        }
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = recordingConfiguration.availableVideoCodecTypes.contains(.h264)
            ? .h264
            : recordingConfiguration.availableVideoCodecTypes.first ?? .h264

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream
        self.outputURL = url
        self.didFinish = false
        self.recordingError = nil

        // Hide the setup UI before the first captured frame.
        NSApp.hide(nil)
        let captureBounds = Self.pointerCaptureBounds(filter: filter, selectedRegion: selectedRegion)
        let traceRecorder = PointerTraceRecorder(captureBounds: captureBounds)
        do {
            try await stream.startCapture()
            _ = traceRecorder.start()
            pointerTraceRecorder = traceRecorder
        } catch {
            if Self.isPermissionDenied(error) { throw ScreenCaptureError.permissionDenied }
            throw error
        }
    }

    func showRecordingAreaShadow() {
        guard let selectedRegion = activeSelectedRegion,
              let screen = Self.screen(for: selectedRegion.displayID) else { return }
        let shadow = RecordingAreaShadowWindowController(screen: screen, area: selectedRegion.rect)
        recordingAreaShadow = shadow
        shadow.show()
    }

    func stopRecording() async throws -> ScreenCaptureRecording {
        recordingAreaShadow?.close()
        recordingAreaShadow = nil
        guard let stream, let outputURL else { throw ScreenCaptureError.notRecording }
        let pointerTrace = pointerTraceRecorder?.stop() ?? .unavailable(bounds: .zero)
        pointerTraceRecorder = nil
        try await stream.stopCapture()
        try await waitForRecordingFinish()
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw ScreenCaptureError.emptyRecording
        }
        self.stream = nil
        self.outputURL = nil
        return ScreenCaptureRecording(url: outputURL, pointerTrace: pointerTrace)
    }

    private static func pointerCaptureBounds(filter: SCContentFilter, selectedRegion: SelectedRegion?) -> CGRect {
        if let selectedRegion,
           let screen = screen(for: selectedRegion.displayID) {
            let selectedRect = selectedRegion.rect
            return CGRect(
                x: screen.frame.minX + selectedRect.minX,
                y: screen.frame.maxY - selectedRect.maxY,
                width: selectedRect.width,
                height: selectedRect.height
            )
        }
        // includedWindows/includedDisplays require macOS 15.2, while the
        // capture service supports macOS 15.0. contentRect is available there
        // and uses screen-point coordinates for both window and display filters.
        let contentRect = filter.contentRect.standardized
        return contentRect.width > 0 && contentRect.height > 0 ? contentRect : .zero
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func chooseDisplay(from displays: [SCDisplay]) throws -> SCDisplay {
        guard let first = displays.first else { throw ScreenCaptureError.noDisplay }
        guard displays.count > 1 else { return first }
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for (index, display) in displays.enumerated() {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }
            choices.addItem(withTitle: screen?.localizedName ?? "Display \(index + 1)")
        }
        let alert = NSAlert()
        alert.messageText = "Choose a display"
        alert.accessoryView = choices
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw ScreenCaptureError.selectionCancelled }
        return displays[choices.indexOfSelectedItem]
    }

    private func chooseContent(for mode: PoachCaptureMode) async throws -> ContentFilterBox {
        try await withCheckedThrowingContinuation { continuation in
            pickerContinuation = continuation
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = mode == .window ? .singleWindow : .singleDisplay
            configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "dev.poach.app"]
            let picker = SCContentSharingPicker.shared
            activePicker = picker
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            picker.present()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let box = ContentFilterBox(filter)
        Task { @MainActor [weak self] in self?.resolvePicker(.success(box)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.resolvePicker(.failure(ScreenCaptureError.selectionCancelled)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let selectionError: ScreenCaptureError = Self.isPermissionDenied(error)
            ? .permissionDenied
            : .selectionFailed(error.localizedDescription)
        Task { @MainActor [weak self] in
            self?.resolvePicker(.failure(selectionError))
        }
    }

    nonisolated private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue { return true }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlyingError)
        }
        return false
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.finishRecording(.success(())) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.finishRecording(.failure(ScreenCaptureServiceError(message: message)))
        }
    }

    private func resolvePicker(_ result: Result<ContentFilterBox, Error>) {
        activePicker?.remove(self)
        activePicker?.isActive = false
        activePicker = nil
        switch result {
        case .success(let filter): pickerContinuation?.resume(returning: filter)
        case .failure(let error): pickerContinuation?.resume(throwing: error)
        }
        pickerContinuation = nil
    }

    private func waitForRecordingFinish() async throws {
        if let recordingError { throw recordingError }
        if didFinish { return }
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    private func finishRecording(_ result: Result<Void, Error>) {
        didFinish = true
        if case .failure(let error) = result { recordingError = error }
        finishContinuation?.resume(with: result)
        finishContinuation = nil
    }
}

private struct ContentFilterBox: @unchecked Sendable {
    let filter: SCContentFilter
    init(_ filter: SCContentFilter) { self.filter = filter }
}

private struct SelectedRegion {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

private struct ScreenCaptureServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class RegionSelectionWindowController {
    static let shared = RegionSelectionWindowController()
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<SelectedRegion, Error>?

    func selectRegion() async throws -> SelectedRegion {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            NSApp.unhide(nil)
            NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
            for screen in NSScreen.screens {
                guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
                let panel = RegionSelectionPanel(
                    contentRect: NSRect(origin: .zero, size: screen.frame.size),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.title = "Poach — Select an area"
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.becomesKeyOnlyIfNeeded = false
                panel.isMovable = false
                panel.contentView = NSHostingView(rootView: RegionSelectionView(
                    onSelect: { [weak self] rect in self?.finish(.success(SelectedRegion(displayID: displayID, rect: rect))) },
                    onCancel: { [weak self] in self?.finish(.failure(ScreenCaptureError.selectionCancelled)) }
                ))
                panel.setFrame(screen.frame, display: true)
                self.panels.append(panel)
                panel.orderFrontRegardless()
                if screen.frame.contains(NSEvent.mouseLocation) {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            guard !panels.isEmpty else {
                self.continuation = nil
                continuation.resume(throwing: ScreenCaptureError.noDisplay)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .filter { $0.title == "Poach" }
                .forEach { $0.orderOut(nil) }
        }
    }

    private func finish(_ result: Result<SelectedRegion, Error>) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if case .failure = result {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first(where: { $0.title == "Poach" })?
                .makeKeyAndOrderFront(nil)
        }
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RecordingAreaShadowWindowController {
    private let screen: NSScreen
    private let area: CGRect
    private var panel: NSPanel?

    init(screen: NSScreen, area: CGRect) {
        self.screen = screen
        self.area = area.integral
    }

    func show() {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Poach — Recording area"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(rootView: RecordingAreaShadowView(area: area))
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }
}

private struct RecordingAreaShadowView: View {
    let area: CGRect

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                var outsideArea = Path(CGRect(origin: .zero, size: size))
                outsideArea.addRect(area)
                context.fill(
                    outsideArea,
                    with: .color(.black.opacity(0.24)),
                    style: FillStyle(eoFill: true)
                )

                context.drawLayer { edge in
                    edge.addFilter(.shadow(color: .black.opacity(0.42), radius: 16, x: 0, y: 3))
                    edge.stroke(Path(area), with: .color(.white.opacity(0.22)), lineWidth: 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
        }
        .background(.clear)
        .accessibilityHidden(true)
    }
}

private struct RegionSelectionView: View {
    let onSelect: (CGRect) -> Void
    let onCancel: () -> Void
    @State private var origin: CGPoint?
    @State private var current: CGPoint?
    @State private var countdownValue: Int?
    @State private var countdownTask: Task<Void, Never>?

    private var selection: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Canvas { context, size in
                    var mask = Path(CGRect(origin: .zero, size: size))
                    if let selection, selection.width > 3, selection.height > 3 {
                        mask.addRect(selection)
                    }
                    context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))
                    if let selection {
                        context.stroke(Path(selection), with: .color(.white), lineWidth: 2)
                        context.stroke(Path(selection.insetBy(dx: 3, dy: 3)), with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard countdownValue == nil else { return }
                        origin = value.startLocation
                        current = value.location
                    })
                    .allowsHitTesting(countdownValue == nil)

                if let countdownValue {
                    PoachCountdown(count: countdownValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Recording starts in \(countdownValue) seconds")
                        .allowsHitTesting(false)
                }

                VStack(spacing: 10) {
                    Text(countdownValue != nil ? "Get ready — recording starts shortly" : selection == nil ? "Drag to select an area" : "Ready to record")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    HStack(spacing: 10) {
                        Button {
                            countdownTask?.cancel()
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 44, height: 32)
                                .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel area selection")
                        .help("Cancel")

                        Button {
                            beginCountdown()
                        } label: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 32)
                                .background(Color.red, in: RoundedRectangle(cornerRadius: 9))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .disabled((selection?.width ?? 0) < 32 || (selection?.height ?? 0) < 32 || countdownValue != nil)
                        .accessibilityLabel("Start recording")
                        .help("Start the three-second countdown (Return)")
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .frame(width: 262, height: 116)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.black.opacity(0.15), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
                .padding(.bottom, 26)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: UserDefaults.standard.string(forKey: "windowEdge") == "left" ? .leading : .trailing)
                .allowsHitTesting(true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.clear)
        .preferredColorScheme(.light)
        .onExitCommand {
            countdownTask?.cancel()
            onCancel()
        }
        .onDisappear { countdownTask?.cancel() }
    }

    private func beginCountdown() {
        guard countdownValue == nil, let selectedArea = selection?.integral else { return }
        countdownTask = Task { @MainActor in
            for count in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) { countdownValue = count }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            countdownValue = nil
            countdownTask = nil
            onSelect(selectedArea)
        }
    }
}
