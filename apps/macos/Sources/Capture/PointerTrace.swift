import AppKit
import CoreGraphics
import Foundation
import os

/// Pointer-only evidence gathered while Poach is actively recording.
/// Coordinates are normalized to the captured bounds with a top-left origin.
struct PointerTrace: Codable {
    let available: Bool
    let coordinateSpace: String
    let origin: String
    let boundsWidth: Double
    let boundsHeight: Double
    let sampleIntervalMs: Double
    let sampleCount: Int
    let insideSampleCount: Int
    let buttonSampleCount: Int
    let scrollCaptured: Bool
    let truncated: Bool
    let events: [PointerTraceEvent]

    static func unavailable(bounds: CGRect) -> PointerTrace {
        PointerTrace(available: false, coordinateSpace: "normalized-capture-bounds", origin: "top-left",
                     boundsWidth: Double(bounds.width), boundsHeight: Double(bounds.height),
                     sampleIntervalMs: 1_000.0 / 120.0, sampleCount: 0, insideSampleCount: 0,
                     buttonSampleCount: 0, scrollCaptured: false, truncated: false, events: [])
    }
}

/// Samples only pointer location and mouse-button state during an explicit capture.
/// It installs no event monitor/tap and never reads keyboard input.
@MainActor
final class PointerTraceRecorder {
    private static let interval: TimeInterval = 1.0 / 120.0
    private static let logger = Logger(subsystem: "dev.poach.app", category: "PointerTrace")

    private let captureBounds: CGRect
    private var timer: Timer?
    private var startedAt: TimeInterval?
    private var trace = PointerTraceBuffer()
    private var lastPoint: CGPoint?
    private var pressedButtons: Set<PointerTraceEvent.Button> = []

    init(captureBounds: CGRect) { self.captureBounds = captureBounds.standardized }

    func start() -> Bool {
        guard captureBounds.width > 0, captureBounds.height > 0 else { return false }
        startedAt = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        return timer != nil
    }

    func stop() -> PointerTrace {
        timer?.invalidate()
        timer = nil
        Self.logger.notice("Pointer trace finished: samples=\(self.trace.sampleCount, privacy: .public), inside=\(self.trace.insideSampleCount, privacy: .public), buttonSamples=\(self.trace.buttonSampleCount, privacy: .public), events=\(self.trace.events.count, privacy: .public)")
        return PointerTrace(available: startedAt != nil, coordinateSpace: "normalized-capture-bounds",
                            origin: "top-left", boundsWidth: Double(captureBounds.width),
                            boundsHeight: Double(captureBounds.height), sampleIntervalMs: Self.interval * 1_000,
                            sampleCount: trace.sampleCount, insideSampleCount: trace.insideSampleCount,
                            buttonSampleCount: trace.buttonSampleCount, scrollCaptured: false,
                            truncated: trace.truncated, events: trace.events)
    }

    private func sample() {
        guard let startedAt else { return }
        let point = NSEvent.mouseLocation
        let inside = captureBounds.contains(point)
        var buttons = Set<PointerTraceEvent.Button>()
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { buttons.insert(.left) }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) { buttons.insert(.right) }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) { buttons.insert(.other) }
        trace.recordSample(inside: inside, buttonHeld: !buttons.isEmpty)
        if trace.sampleCount == 1 {
            Self.logger.info("First pointer sample: insideCapture=\(inside, privacy: .public), buttonCount=\(buttons.count, privacy: .public)")
        }

        // Button edges can happen outside a selected region; flag those boundary
        // events instead of silently leaving a down/drag sequence unfinished.
        for button in buttons.subtracting(pressedButtons) {
            append(.down, button: button, point: point, startedAt: startedAt, withinCapture: inside)
        }
        for button in pressedButtons.subtracting(buttons) {
            append(.up, button: button, point: point, startedAt: startedAt, withinCapture: inside)
        }
        if buttons.isEmpty, inside, lastPoint != point {
            append(.move, button: nil, point: point, startedAt: startedAt, withinCapture: true)
        }
        if !buttons.isEmpty, lastPoint != point {
            for button in buttons { append(.drag, button: button, point: point, startedAt: startedAt, withinCapture: inside) }
        }
        pressedButtons = buttons
        lastPoint = point
    }

    private func append(_ kind: PointerTraceEvent.Kind, button: PointerTraceEvent.Button?, point: CGPoint,
                        startedAt: TimeInterval, withinCapture: Bool) {
        let x = min(1, max(0, (point.x - captureBounds.minX) / captureBounds.width))
        let y = min(1, max(0, (captureBounds.maxY - point.y) / captureBounds.height))
        trace.append(PointerTraceEvent(timeMs: Int(max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()),
                                       kind: kind, x: x, y: y, button: button, withinCapture: withinCapture))
    }
}
