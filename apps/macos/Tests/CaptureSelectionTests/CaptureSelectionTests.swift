import CoreGraphics
import Foundation

@main enum CaptureSelectionTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let pill = CGSize(width: 168, height: 48)
        // Room below: centred on the area, 12 points below its outline.
        precondition(CaptureTargetGeometry.attachedPillFrame(for: CGRect(x: 200, y: 100, width: 400, height: 300), pillSize: pill, in: screen)
            == CGRect(x: 316, y: 412, width: 168, height: 48))
        // An area narrower than the pill: still centred on it.
        precondition(CaptureTargetGeometry.attachedPillFrame(for: CGRect(x: 450, y: 100, width: 100, height: 200), pillSize: pill, in: screen)
            == CGRect(x: 416, y: 312, width: 168, height: 48))
        // No room below: 12 points above the area.
        precondition(CaptureTargetGeometry.attachedPillFrame(for: CGRect(x: 200, y: 400, width: 400, height: 380), pillSize: pill, in: screen)
            == CGRect(x: 316, y: 340, width: 168, height: 48))
        // Near a side edge: stays on screen.
        precondition(CaptureTargetGeometry.attachedPillFrame(for: CGRect(x: 0, y: 100, width: 60, height: 60), pillSize: pill, in: screen).minX == 8)
        // Area fills the screen: inside its bottom edge.
        precondition(CaptureTargetGeometry.attachedPillFrame(for: screen, pillSize: pill, in: screen)
            == CGRect(x: 416, y: 736, width: 168, height: 48))
        timerModel()
        print("Capture timer model passed.")
        targetGeometry()
        print("Capture target geometry passed.")
    }

    private static func timerModel() {
        precondition(PoachCaptureTimer(storedSeconds: 0) == .off)
        precondition(PoachCaptureTimer(storedSeconds: 3) == .three)
        precondition(PoachCaptureTimer(storedSeconds: 10) == .ten)
        precondition(PoachCaptureTimer(storedSeconds: 5) == .off)
        precondition(PoachCaptureTimer(storedSeconds: -1) == .off)
        precondition(PoachCaptureTimer.off.stepped(by: 1) == .three)
        precondition(PoachCaptureTimer.ten.stepped(by: 1) == .ten)
        precondition(PoachCaptureTimer.off.stepped(by: -1) == .off)
        precondition(PoachCaptureTimer.allCases.map(\.shortTitle) == ["Off", "3s", "10s"])
        precondition(PoachCaptureTimer.three.spokenTitle == "3 seconds")
        // The lens is concentric with the 196 x 48 pill at both ends: 6 pt inside at rest,
        // 6 pt outside while pressed, the same above, below and at the side.
        let lens = CaptureTimerLensLayout(pillWidth: 196, pillHeight: 48)
        precondition(lens.restingSize == (76, 36) && lens.liftedSize == (100, 60))
        precondition(lens.centre(of: 0) - lens.restingSize.width / 2 == 6)
        precondition(lens.centre(of: 2) + lens.restingSize.width / 2 == 196 - 6)
        precondition(lens.centre(of: 0) - lens.liftedSize.width / 2 == -6)
        precondition(lens.centre(of: 2) + lens.liftedSize.width / 2 == 196 + 6)
        precondition((48 - lens.liftedSize.height) / 2 == -6 && (48 - lens.restingSize.height) / 2 == 6)
        precondition(lens.centre(of: 1) == 98)
        // A press past either end holds the lens at the end position; the nearest option wins.
        precondition(lens.clampedCentre(-40) == lens.centre(of: 0) && lens.clampedCentre(400) == lens.centre(of: 2))
        precondition(lens.index(atX: 10) == 0 && lens.index(atX: 98) == 1 && lens.index(atX: 180) == 2)
        precondition(lens.index(atX: -40) == 0 && lens.index(atX: 400) == 2)
        precondition(PoachCaptureTimer.ten.index == 2)
    }

    private static func targetGeometry() {
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: true) == 0)
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: false) == 2)
        precondition(CaptureTargetGeometry.cycledIndex(from: 2, count: 3, forward: true) == 0)
        precondition(CaptureTargetGeometry.cycledIndex(from: 0, count: 3, forward: false) == 2)
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 0, forward: true) == nil)
        // A window on a secondary display above the primary one (negative global y).
        precondition(CaptureTargetGeometry.appKitRect(fromGlobalTopLeft: CGRect(x: 10, y: -1000, width: 200, height: 100), primaryScreenHeight: 956) == CGRect(x: 10, y: 1856, width: 200, height: 100))
    }
}
