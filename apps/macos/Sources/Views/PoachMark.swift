import AppKit
import SwiftUI

/// The two lobes leave a transparent cinch at menu-bar scale.
struct PoachPouchShape: Shape {
    @MainActor
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(PoachPouchShape().path(in: rect).cgPath)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Poach"
        return image
    }()

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 6.3, y: 6.4))
        path.addCurve(to: CGPoint(x: 5.2, y: 3.2), control1: CGPoint(x: 6, y: 5.4), control2: CGPoint(x: 4.5, y: 4.3))
        path.addCurve(to: CGPoint(x: 9.4, y: 3.1), control1: CGPoint(x: 6.2, y: 1.7), control2: CGPoint(x: 8.1, y: 3.6))
        path.addCurve(to: CGPoint(x: 13.3, y: 2.2), control1: CGPoint(x: 10.7, y: 2.7), control2: CGPoint(x: 12.2, y: 1))
        path.addCurve(to: CGPoint(x: 11.5, y: 6.4), control1: CGPoint(x: 14.2, y: 3.3), control2: CGPoint(x: 12.2, y: 5.1))
        path.closeSubpath()
        path.move(to: CGPoint(x: 6.4, y: 7.55))
        path.addCurve(to: CGPoint(x: 2.7, y: 13.3), control1: CGPoint(x: 4.3, y: 8.8), control2: CGPoint(x: 2.5, y: 11))
        path.addCurve(to: CGPoint(x: 8.5, y: 16.4), control1: CGPoint(x: 2.9, y: 15.7), control2: CGPoint(x: 5.2, y: 16.4))
        path.addCurve(to: CGPoint(x: 14.7, y: 12.9), control1: CGPoint(x: 12.1, y: 16.4), control2: CGPoint(x: 14.7, y: 15.6))
        path.addCurve(to: CGPoint(x: 11.4, y: 7.55), control1: CGPoint(x: 14.7, y: 10.8), control2: CGPoint(x: 13.1, y: 8.7))
        path.closeSubpath()
        let tilt = CGAffineTransform(translationX: 9, y: 9)
            .rotated(by: .pi / 15)
            .translatedBy(x: -9, y: -9)
        return path.applying(tilt)
            .applying(CGAffineTransform(scaleX: rect.width / 18, y: rect.height / 18))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
