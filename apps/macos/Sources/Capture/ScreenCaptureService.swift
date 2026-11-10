import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit
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
    case screenshotUnavailable
    case screenshotRequiresNewerMacOS
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
        case .screenshotRequiresNewerMacOS:
            "Taking a screenshot in Poach requires macOS 15 or later. You can still import an existing image."
        case .screenshotUnavailable:
            "Poach couldn’t create a PNG from this selection."
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
    let epochRange: ClosedRange<Int>?
    let sizePoints: CGSize
}

@available(macOS 15.0, *)
@MainActor
final class ScreenCaptureService: NSObject, SCRecordingOutputDelegate {
    private var captureSizePoints = CGSize.zero
    private var stream: SCStream?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var didFinish = false
    private var recordingError: Error?
    private var pointerTraceRecorder: PointerTraceRecorder?
    private var startedAtEpochMs: Int?
    private var activeSelectedRegion: SelectedRegion?
    private var recordingAreaShadow: RecordingAreaShadowWindowController?

    /// Lets the person choose what to capture, runs the optional countdown, then builds the filter.
    /// The countdown overlay is gone before this returns, so it never appears in the capture.
    private func selectTarget(mode: PoachCaptureMode, screenshot: Bool) async throws
        -> (filter: SCContentFilter, selectedRegion: SelectedRegion?) {
        let target = try await CaptureSelectionWindowController.shared.select(mode: mode, screenshot: screenshot)
        if let (outline, screen) = Self.outline(for: target) {
            try await CaptureCountdownController.shared.run(seconds: PoachCaptureTimer.current.seconds, outline: outline, on: screen)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if Self.isPermissionDenied(error) { throw ScreenCaptureError.permissionDenied }
            throw error
        }
        switch target {
        case .area(let region):
            return (try Self.displayFilter(displayID: region.displayID, content: content), region)
        case .display(let displayID):
            return (try Self.displayFilter(displayID: displayID, content: content), nil)
        case .window(let candidate):
            guard let window = content.windows.first(where: { $0.windowID == candidate.windowID }) else {
                throw ScreenCaptureError.selectionFailed("That window is no longer available.")
            }
            return (SCContentFilter(desktopIndependentWindow: window), nil)
        }
    }

    /// A display capture that leaves out Poach's own windows.
    private static func displayFilter(displayID: CGDirectDisplayID, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplay
        }
        let poachApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        guard !poachApplications.isEmpty else { throw ScreenCaptureError.selectionFailed("Poach could not exclude its windows from this display.") }
        return SCContentFilter(display: display, excludingApplications: poachApplications, exceptingWindows: [])
    }

    /// The target's outline in AppKit global coordinates and the screen that shows its countdown.
    private static func outline(for target: CaptureTarget) -> (CGRect, NSScreen)? {
        switch target {
        case .area(let region):
            guard let screen = screen(for: region.displayID) else { return nil }
            return (appKitRect(region), screen)
        case .display(let displayID):
            guard let screen = screen(for: displayID) else { return nil }
            return (screen.frame, screen)
        case .window(let candidate):
            guard let primary = NSScreen.screens.first else { return nil }
            let rect = CaptureTargetGeometry.appKitRect(fromGlobalTopLeft: candidate.frame, primaryScreenHeight: primary.frame.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? primary
            return (rect, screen)
        }
    }

    /// Converts a screen-local, top-left area to AppKit global coordinates.
    private static func appKitRect(_ region: SelectedRegion) -> CGRect {
        guard let screen = screen(for: region.displayID) else { return region.rect }
        return CGRect(
            x: screen.frame.minX + region.rect.minX,
            y: screen.frame.maxY - region.rect.maxY,
            width: region.rect.width,
            height: region.rect.height
        )
    }

    private static var poachWindowNumbers: [Int] {
        NSApp.windows.map(\.windowNumber).filter { $0 > 0 }
    }

    private static func isPoach(_ application: SCRunningApplication?) -> Bool {
        guard let application else { return false }
        return application.processID == ProcessInfo.processInfo.processIdentifier
            || application.bundleIdentifier == poachBundleID
    }

    private static func displayFilter(for display: SCDisplay, in content: SCShareableContent) throws -> SCContentFilter {
        let excluded = content.applications.filter { isPoach($0) }
        guard excluded.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw ScreenCaptureError.selectionFailed("Poach could not exclude its windows from this display.")
        }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    func captureScreenshot(mode: PoachCaptureMode) async throws -> (url: URL, capturedAtEpochMs: Int, sizePoints: CGSize) {
        let (filter, region) = try await selectTarget(mode: mode, screenshot: true)
        NSApp.windows.filter { $0.title == "Poach" }.forEach { $0.orderOut(nil) }
        let sourceSize = region?.rect.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        guard sourceSize.width > 0, sourceSize.height > 0, scale > 0 else {
            throw ScreenCaptureError.screenshotUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((sourceSize.width * scale).rounded()))
        configuration.height = max(1, Int((sourceSize.height * scale).rounded()))
        configuration.showsCursor = false
        if let region { configuration.sourceRect = region.rect }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let capturedAtEpochMs = Int((Date().timeIntervalSince1970 * 1000).rounded())
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.screenshotUnavailable
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "Poach", directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "screenshot-\(UUID().uuidString).png")
        guard fm.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (url, capturedAtEpochMs, sourceSize)
    }

    func startRecording(mode: PoachCaptureMode) async throws {
        let (filter, selectedRegion) = try await selectTarget(mode: mode, screenshot: false)
        activeSelectedRegion = selectedRegion
        let selectedRect: CGRect?
        selectedRect = selectedRegion?.rect

        let sourceSize = selectedRect?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        captureSizePoints = sourceSize
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
            startedAtEpochMs = Int((Date().timeIntervalSince1970 * 1000).rounded())
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
        let stoppedAtEpochMs = Int((Date().timeIntervalSince1970 * 1000).rounded())
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
        let epochRange = startedAtEpochMs.flatMap { start in
            start <= stoppedAtEpochMs ? start...stoppedAtEpochMs : nil
        }
        return ScreenCaptureRecording(url: outputURL, pointerTrace: pointerTrace, epochRange: epochRange, sizePoints: captureSizePoints)
    }

    private static func pointerCaptureBounds(filter: SCContentFilter, selectedRegion: SelectedRegion?) -> CGRect {
        if let selectedRegion, screen(for: selectedRegion.displayID) != nil {
            return appKitRect(selectedRegion)
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


private struct ScreenCaptureServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
        panel.contentView = TransparentHostingView(rootView: RecordingAreaShadowView(area: area))
        panel.backgroundColor = .clear
        panel.isOpaque = false
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
