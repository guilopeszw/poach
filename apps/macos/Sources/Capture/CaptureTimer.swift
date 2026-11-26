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

    static var current: PoachCaptureTimer {
        PoachCaptureTimer(storedSeconds: UserDefaults.standard.integer(forKey: storageKey))
    }
}

/// Where the timer lens sits in the pill. At either end the lens is concentric with the pill, so
/// the gap between their edges is the same above, below and at the side: `inset` inside the pill
/// at rest, `overhang` outside it while pressed (after a reference the user shared on Nov 26).
/// The options are centred where the resting lens stops, not on equal thirds of the pill.
struct CaptureTimerLensLayout {
    /// The pill the options cover.
    let pillWidth: Double
    let pillHeight: Double
    var count = PoachCaptureTimer.allCases.count

    static let inset = 6.0
    static let overhang = 6.0
    static let restingWidth = 60.0

    var restingSize: (width: Double, height: Double) {
        (Self.restingWidth, pillHeight - 2 * Self.inset)
    }

    /// Grown by `inset + overhang` on every side, so it keeps the resting lens's centre.
    var liftedSize: (width: Double, height: Double) {
        let grow = 2 * (Self.inset + Self.overhang)
        return (Self.restingWidth + grow, pillHeight - 2 * Self.inset + grow)
    }

    private var step: Double {
        count > 1 ? (pillWidth - 2 * Self.inset - Self.restingWidth) / Double(count - 1) : 0
    }

    /// The lens centre (and label centre) of option `index`, from the pill's leading edge.
    func centre(of index: Int) -> Double {
        Self.inset + Self.restingWidth / 2 + step * Double(index)
    }

    /// A pointer x held between the first and last centres, so the lens never leaves the
    /// concentric position at either end.
    func clampedCentre(_ x: Double) -> Double {
        min(max(x, centre(of: 0)), centre(of: count - 1))
    }

    /// The option whose centre is nearest to `x`.
    func index(atX x: Double) -> Int {
        guard step > 0 else { return 0 }
        let raw = ((x - centre(of: 0)) / step).rounded()
        return Int(min(max(raw, 0), Double(count - 1)))
    }
}
