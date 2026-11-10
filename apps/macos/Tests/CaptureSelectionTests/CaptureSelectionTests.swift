import CoreGraphics
import Foundation

@main enum CaptureSelectionTests {
    static func main() {
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
    }

    private static func targetGeometry() {
        let poach: pid_t = 99
        let front = CaptureWindowCandidate(windowID: 1, ownerPID: 10, appName: "Safari", title: "Apple", frame: CGRect(x: 0, y: 0, width: 400, height: 300), layer: 0)
        let back = CaptureWindowCandidate(windowID: 2, ownerPID: 11, appName: "Xcode", title: "", frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0)
        let menu = CaptureWindowCandidate(windowID: 3, ownerPID: 12, appName: "Menu", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 33), layer: 24)
        let tiny = CaptureWindowCandidate(windowID: 4, ownerPID: 13, appName: "Tiny", title: "", frame: CGRect(x: 0, y: 0, width: 20, height: 20), layer: 0)
        let mine = CaptureWindowCandidate(windowID: 5, ownerPID: poach, appName: "Poach", title: "", frame: CGRect(x: 0, y: 0, width: 1470, height: 956), layer: 0)
        let selectable = CaptureTargetGeometry.selectableWindows([mine, menu, tiny, front, back], excludingPID: poach)
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
            kCGWindowName as String: "Apple", kCGWindowLayer as String: 0,
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 300, height: 200).dictionaryRepresentation
        ], [kCGWindowOwnerPID as String: 10]])
        precondition(parsed.count == 1 && parsed[0].windowID == 7 && parsed[0].frame == CGRect(x: 1, y: 2, width: 300, height: 200))
    }
}
