import Foundation

@main struct BrowserEvidenceTests {
    static func main() throws {
        let element: [String: Any] = ["tag": "div", "role": "", "classes": "fixture"]
        func state(_ time: Int) -> [String: Any] { ["atMs": time, "rect": [0, 0, 100, 50], "styles": ["color": "red"], "text": "Ready"] }
        var raw: [String: Any] = ["version": 1, "origin": "https://example.com", "target": element, "startedAtEpochMs": 100_000, "durationMs": 20_000, "events": [], "states": [state(0), state(1_000), state(10_000), state(19_000)], "animations": [], "targetRemoved": false]
        let old = try PoachBrowserEvidence.decode(JSONSerialization.data(withJSONObject: raw))
        precondition(old.devicePixelRatio == nil)
        raw["devicePixelRatio"] = 2
        raw["viewport"] = ["width": 1000, "height": 800]
        let parsed = try PoachBrowserEvidence.decode(JSONSerialization.data(withJSONObject: raw))
        let aligned = parsed.aligned(to: 105_000...112_000)!
        precondition(aligned.videoOffsetMs == -5_000)
        precondition(aligned.states.map(\.atMs) == [1_000, 10_000])
        let roundTrip = try JSONDecoder().decode(PoachBrowserEvidence.self, from: JSONEncoder().encode(aligned))
        precondition(roundTrip.devicePixelRatio == 2 && roundTrip.viewport?.width == 1000)
        raw["devicePixelRatio"] = -1
        do { _ = try PoachBrowserEvidence.decode(JSONSerialization.data(withJSONObject: raw)); fatalError("Invalid ratio accepted") } catch {}
        print("Browser evidence compatibility, alignment and validation passed")
    }
}
