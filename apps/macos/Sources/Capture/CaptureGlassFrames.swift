import CoreGraphics
import CoreVideo
import Foundation

/// The output callback and the Metal renderer exchange only the most recent frame.
/// Synchronization is confined here; no capture pixels leave this in-memory store.
final class CaptureGlassFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var pixelBuffer: CVPixelBuffer?
    private var fixture: CGImage?

    func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = value
        if !value { pixelBuffer = nil; fixture = nil }
    }

    func replace(with buffer: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        let first = pixelBuffer == nil
        pixelBuffer = buffer
        return first
    }

    func latest() -> (CVPixelBuffer?, CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        return (pixelBuffer, fixture)
    }

    #if DEBUG
    func setFixture(_ image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        fixture = image
    }
    #endif
}

