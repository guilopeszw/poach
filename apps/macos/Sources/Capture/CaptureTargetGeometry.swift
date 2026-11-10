import CoreGraphics
import Foundation

/// An on-screen window that could be captured, as reported by `CGWindowListCopyWindowInfo`.
/// `frame` uses global top-left coordinates (origin at the primary display's top-left, y down).
struct CaptureWindowCandidate: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let layer: Int

    var spokenName: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

/// Pure helpers for choosing a capture target. Kept free of AppKit so they can be tested with `swiftc`.
enum CaptureTargetGeometry {
    static let minimumWindowSide: CGFloat = 40

    static func candidates(fromWindowInfo info: [[String: Any]]) -> [CaptureWindowCandidate] {
        info.compactMap { entry in
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return CaptureWindowCandidate(
                windowID: number,
                ownerPID: pid,
                appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String ?? "",
                frame: frame,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    /// Normal app windows only (layer 0), large enough to be a real target, never Poach's own.
    static func selectableWindows(_ frontToBack: [CaptureWindowCandidate], excludingPID: pid_t) -> [CaptureWindowCandidate] {
        frontToBack.filter {
            $0.layer == 0
                && $0.frame.width >= minimumWindowSide
                && $0.frame.height >= minimumWindowSide
                && $0.ownerPID != excludingPID
        }
    }

    /// The frontmost selectable window containing `point` (global top-left coordinates).
    static func window(at point: CGPoint, in selectable: [CaptureWindowCandidate]) -> CaptureWindowCandidate? {
        selectable.first { $0.frame.contains(point) }
    }

    static func cycledIndex(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return ((current + (forward ? 1 : -1)) % count + count) % count
    }

    static func appKitRect(fromGlobalTopLeft rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
