import Foundation

/// Delay before a capture starts. Persisted so the last choice carries to the next capture.
enum PoachCaptureTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case ten = 10

    static let storageKey = "captureTimerSeconds"

    /// Unknown stored values (for example from an older build) read as Off.
    init(storedSeconds: Int) {
        self = PoachCaptureTimer(rawValue: storedSeconds) ?? .off
    }

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .off: "Off"
        case .three: "3s"
        case .ten: "10s"
        }
    }

    var spokenTitle: String {
        switch self {
        case .off: "Off"
        case .three: "3 seconds"
        case .ten: "10 seconds"
        }
    }

    /// Moves through Off, 3s, 10s without wrapping.
    func stepped(by delta: Int) -> PoachCaptureTimer {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[min(max(index + delta, 0), all.count - 1)]
    }

    static var current: PoachCaptureTimer {
        PoachCaptureTimer(storedSeconds: UserDefaults.standard.integer(forKey: storageKey))
    }
}
