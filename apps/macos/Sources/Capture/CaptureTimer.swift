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

    /// Position in `allCases`, left to right.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The option under `x` on a track split into equal segments; positions past either end clamp.
    static func option(atX x: Double, trackWidth: Double) -> PoachCaptureTimer {
        guard trackWidth > 0 else { return .off }
        let all = allCases
        let segment = Int((x / trackWidth * Double(all.count)).rounded(.down))
        return all[min(max(segment, 0), all.count - 1)]
    }

    static var current: PoachCaptureTimer {
        PoachCaptureTimer(storedSeconds: UserDefaults.standard.integer(forKey: storageKey))
    }
}
