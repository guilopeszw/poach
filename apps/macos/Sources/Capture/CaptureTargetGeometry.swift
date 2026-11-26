import CoreGraphics
import Foundation

/// Pure helpers for choosing a capture target. Kept free of AppKit so they can be tested with `swiftc`.
enum CaptureTargetGeometry {
    static func cycledIndex(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return ((current + (forward ? 1 : -1)) % count + count) % count
    }

    /// Global top-left coordinates (ScreenCaptureKit, CGWindowList) to AppKit bottom-left.
    static func appKitRect(fromGlobalTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where the capture pill sits for a selected area, in the same top-left coordinates as `area`.
    /// The pill is centred on the area, `gap` points away from its outline: below it when there is
    /// room, otherwise above it, otherwise just inside its bottom edge. It never leaves `bounds`
    /// (inset by `margin`).
    static func attachedPillFrame(for area: CGRect, pillSize: CGSize, in bounds: CGRect,
                                  gap: CGFloat = 12, margin: CGFloat = 8) -> CGRect {
        let x = min(max(area.midX - pillSize.width / 2, bounds.minX + margin), bounds.maxX - margin - pillSize.width)
        let below = area.maxY + gap
        let above = area.minY - gap - pillSize.height
        let y: CGFloat
        if below + pillSize.height <= bounds.maxY - margin {
            y = below
        } else if above >= bounds.minY + margin {
            y = above
        } else {
            y = min(area.maxY, bounds.maxY - margin) - pillSize.height - margin
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: pillSize)
    }
}
