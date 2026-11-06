import Foundation

struct PointerTraceEvent: Codable {
    enum Kind: String, Codable { case move, down, up, drag }
    enum Button: String, Codable { case left, right, other }

    let timeMs: Int
    let kind: Kind
    let x: Double
    let y: Double
    let button: Button?
    let withinCapture: Bool
}

struct PointerTraceBuffer {
    private let maximumEvents: Int
    private(set) var events: [PointerTraceEvent] = []
    private(set) var truncated = false
    private(set) var sampleCount = 0
    private(set) var insideSampleCount = 0
    private(set) var buttonSampleCount = 0

    init(maximumEvents: Int = 5_000) {
        self.maximumEvents = maximumEvents
    }

    mutating func recordSample(inside: Bool, buttonHeld: Bool) {
        sampleCount += 1
        if inside { insideSampleCount += 1 }
        if buttonHeld { buttonSampleCount += 1 }
    }

    mutating func append(_ event: PointerTraceEvent) {
        guard events.count < maximumEvents else { truncated = true; return }
        events.append(event)
    }
}
