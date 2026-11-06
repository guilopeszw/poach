import Foundation

@main enum PointerTraceBufferTests {
    static func main() {
        // Arrange
        var trace = PointerTraceBuffer(maximumEvents: 2)
        trace.recordSample(inside: true, buttonHeld: false)
        trace.append(event(at: 10))
        trace.append(event(at: 20))

        // Act
        trace.recordSample(inside: true, buttonHeld: true)
        trace.append(event(at: 30))

        // Assert
        precondition(trace.sampleCount == 2)
        precondition(trace.insideSampleCount == 2)
        precondition(trace.buttonSampleCount == 1)
        precondition(trace.events.count == 2)
        precondition(trace.truncated)
        print("Pointer trace cap accounting passed.")
    }

    private static func event(at timeMs: Int) -> PointerTraceEvent {
        PointerTraceEvent(timeMs: timeMs, kind: .move, x: 0.5, y: 0.5, button: nil, withinCapture: true)
    }
}
