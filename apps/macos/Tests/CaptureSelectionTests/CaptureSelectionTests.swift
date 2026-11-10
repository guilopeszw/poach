import CoreGraphics
import Foundation

@main enum CaptureSelectionTests {
    static func main() {
        timerModel()
        print("Capture timer model passed.")
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
}
