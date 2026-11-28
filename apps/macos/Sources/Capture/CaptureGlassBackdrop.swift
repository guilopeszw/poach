import AppKit
import CoreMedia
import CoreVideo
import Observation
@preconcurrency import ScreenCaptureKit

/// A selection-only, memory-only desktop sample. It has no recording output, audio, cursor,
/// file URL or handoff integration, and is stopped when the selection overlay closes.
@MainActor
@Observable
final class CaptureGlassBackdrop {
    private(set) var isReady = false
    @ObservationIgnored let frames = CaptureGlassFrames()
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var output: CaptureGlassStreamOutput?

    func start(displayID: CGDirectDisplayID) {
        guard #available(macOS 26.0, *), CGPreflightScreenCaptureAccess(), startup == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        frames.setEnabled(true)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !ownApps.isEmpty else { return }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                }
                configuration.width = screen.map { Int($0.frame.width * $0.backingScaleFactor) } ?? display.width
                configuration.height = screen.map { Int($0.frame.height * $0.backingScaleFactor) } ?? display.height
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.queueDepth = 3
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.colorSpaceName = CGColorSpace.sRGB
                let output = CaptureGlassStreamOutput(frames: frames) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.frames.latest().0 != nil else { return }
                        self.isReady = true
                    }
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "dev.poach.glass-preview"))
                self.output = output
                self.stream = stream
                try await stream.startCapture()
                if Task.isCancelled { try? await stream.stopCapture() }
            } catch {
                // Permission or GPU failures retain the native-glass fallback and never block selection.
                self.stop()
            }
        }
    }

    func stop() {
        startup?.cancel()
        startup = nil
        let activeStream = stream
        stream = nil
        output = nil
        frames.setEnabled(false)
        isReady = false
        Task { try? await activeStream?.stopCapture() }
    }

    #if DEBUG
    func useFixture(_ image: CGImage) {
        frames.setFixture(image)
        isReady = true
    }
    #endif
}

private final class CaptureGlassStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let frames: CaptureGlassFrames
    let onFirstFrame: @Sendable () -> Void

    init(frames: CaptureGlassFrames, onFirstFrame: @escaping @Sendable () -> Void) {
        self.frames = frames
        self.onFirstFrame = onFirstFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if frames.replace(with: buffer) { onFirstFrame() }
    }
}
