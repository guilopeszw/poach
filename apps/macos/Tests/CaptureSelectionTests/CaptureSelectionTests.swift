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
        // The option under a drag or click across a 150-point track (three 50-point segments).
        precondition(PoachCaptureTimer.option(atX: 10, trackWidth: 150) == .off)
        precondition(PoachCaptureTimer.option(atX: 75, trackWidth: 150) == .three)
        precondition(PoachCaptureTimer.option(atX: 149, trackWidth: 150) == .ten)
        precondition(PoachCaptureTimer.option(atX: -40, trackWidth: 150) == .off)
        precondition(PoachCaptureTimer.option(atX: 400, trackWidth: 150) == .ten)
        precondition(PoachCaptureTimer.option(atX: 20, trackWidth: 0) == .off)
        precondition(PoachCaptureTimer.ten.index == 2)
    }

    private static func targetGeometry() {
        let poach: pid_t = 99
        let front = CaptureWindowCandidate(windowID: 1, ownerPID: 10, appName: "Safari", title: "Apple", frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0)
        let back = CaptureWindowCandidate(windowID: 2, ownerPID: 11, appName: "Xcode", title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0)
        let menu = CaptureWindowCandidate(windowID: 3, ownerPID: 12, appName: "Menu", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 33), layer: 24)
        let tiny = CaptureWindowCandidate(windowID: 4, ownerPID: 13, appName: "Tiny", title: "", frame: CGRect(x: 0, y: 0, width: 20, height: 20), layer: 0)
        let mine = CaptureWindowCandidate(windowID: 5, ownerPID: poach, appName: "Poach", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 956), layer: 0)
        let invisible = CaptureWindowCandidate(windowID: 6, ownerPID: 14, appName: "Overlay", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 956), layer: 0, alpha: 0)
        let selectable = CaptureTargetGeometry.selectableWindows([mine, invisible, menu, tiny, front, back], excludingPID: poach)
        precondition(selectable == [front, back])
        precondition(CaptureTargetGeometry.window(at: CGPoint(x: 150, y: 150), in: selectable) == front)
        precondition(CaptureTargetGeometry.window(at: CGPoint(x: 700, y: 500), in: selectable) == back)
        precondition(CaptureTargetGeometry.window(at: CGPoint(x: 1400, y: 900), in: selectable) == nil)
        precondition(front.spokenName == "Safari — Apple" && back.spokenName == "Xcode")
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: true) == 0)
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 3, forward: false) == 2)
        precondition(CaptureTargetGeometry.cycledIndex(from: 2, count: 3, forward: true) == 0)
        precondition(CaptureTargetGeometry.cycledIndex(from: 0, count: 3, forward: false) == 2)
        precondition(CaptureTargetGeometry.cycledIndex(from: nil, count: 0, forward: true) == nil)
        // A window on a secondary display above the primary one (negative global y).
        precondition(CaptureTargetGeometry.appKitRect(fromGlobalTopLeft: CGRect(x: 10, y: -1000, width: 200, height: 100), primaryScreenHeight: 956) == CGRect(x: 10, y: 1856, width: 200, height: 100))
        let parsed = CaptureTargetGeometry.candidates(fromWindowInfo: [[
            kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 10, kCGWindowOwnerName as String: "Safari",
            kCGWindowName as String: "Apple", kCGWindowLayer as String: 0, kCGWindowAlpha as String: 0.5,
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 300, height: 200).dictionaryRepresentation
        ], [kCGWindowOwnerPID as String: 10]])
        precondition(parsed.count == 1 && parsed[0].windowID == 7 && parsed[0].frame == CGRect(x: 1, y: 2, width: 300, height: 200) && parsed[0].alpha == 0.5)
    }
}
