import Foundation

struct PoachBrowserEvidence: Codable {
    struct Element: Codable {
        let tag: String
        let role: String
        let classes: String
    }

    struct Event: Codable {
        let atMs: Int
        let type: String
        let target: Element
        let point: [Int]?
        let insideTarget: Bool?
    }

    struct State: Codable {
        let atMs: Int
        let rect: [Double]
        let styles: [String: String]
        let text: String
        let indicators: [Indicator]?
    }

    struct Indicator: Codable {
        let target: Element
        let rect: [Double]
        let value: String
    }

    struct Animation: Codable {
        struct Frame: Codable {
            let offset: Double
            let easing: String
            let styles: [String: String]
        }
        let atMs: Int
        let target: Element
        let durationMs: Double
        let delayMs: Double
        let easing: String
        let keyframes: [Frame]
    }

    struct Viewport: Codable { let width: Double; let height: Double }
    var devicePixelRatio: Double?
    var viewport: Viewport?

    let version: Int
    let origin: String
    let target: Element
    let startedAtEpochMs: Int
    let durationMs: Int
    var events: [Event]
    var states: [State]
    var animations: [Animation]
    let targetRemoved: Bool
    // Add this offset to Chrome's atMs values to estimate positions in the video.
    var videoOffsetMs: Int?

    var stylesAtCaptureStart: [String: String] {
        let captureStartMs = -(videoOffsetMs ?? 0)
        return (states.last { $0.atMs <= captureStartMs } ?? states.first)?.styles ?? [:]
    }

    static let byteLimit = 256 * 1024

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit, var capture = try? JSONDecoder().decode(Self.self, from: data),
              capture.version == 1, (0...90_000).contains(capture.durationMs),
              capture.startedAtEpochMs > 0, capture.startedAtEpochMs < 10_000_000_000_000,
              let origin = URLComponents(string: capture.origin), ["http", "https"].contains(origin.scheme),
              origin.host != nil, origin.user == nil, origin.password == nil,
              origin.path.isEmpty, origin.query == nil, origin.fragment == nil,
              capture.events.count <= 96, (1...48).contains(capture.states.count),
              capture.animations.count <= 16, capture.animations.allSatisfy({ $0.keyframes.count <= 8 }),
              capture.states.allSatisfy({ $0.rect.count == 4 && ($0.indicators?.count ?? 0) <= 4 }),
              capture.events.allSatisfy({ $0.point == nil || $0.point?.count == 2 }),
              (capture.events.map(\.atMs) + capture.states.map(\.atMs) + capture.animations.map(\.atMs))
                .allSatisfy({ (0...capture.durationMs).contains($0) }) else { throw ImportError.invalidFile }
        if let ratio = capture.devicePixelRatio, !ratio.isFinite || ratio <= 0 || ratio > 16 { throw ImportError.invalidFile }
        if let viewport = capture.viewport, !viewport.width.isFinite || !viewport.height.isFinite || viewport.width <= 0 || viewport.height <= 0 { throw ImportError.invalidFile }
        capture.videoOffsetMs = nil
        return capture
    }

    func aligned(to recording: ClosedRange<Int>) -> Self? {
        guard recording.overlaps(startedAtEpochMs...(startedAtEpochMs + durationMs)) else { return nil }
        var capture = self
        capture.videoOffsetMs = startedAtEpochMs - recording.lowerBound
        let start = recording.lowerBound - startedAtEpochMs
        let end = recording.upperBound - startedAtEpochMs
        capture.events = events.filter { (start - 1_000...end + 1_000).contains($0.atMs) }
        capture.animations = animations.filter { (start - 1_000...end + 1_000).contains($0.atMs) }
        let baseline = states.filter { $0.atMs <= start }.max { $0.atMs < $1.atMs }
        capture.states = states.filter { (start - 1_000...end + 1_000).contains($0.atMs) || $0.atMs == baseline?.atMs }
        return capture
    }

    private enum ImportError: LocalizedError {
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Poach couldn’t read the Chrome capture."
            }
        }
    }
}
