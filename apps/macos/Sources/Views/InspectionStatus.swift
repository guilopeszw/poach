import SwiftUI

@MainActor
final class InspectionStatus: ObservableObject {
    @Published var steps: [String] = []
    @Published var seconds: Int?
    @Published var manualExpansion: Bool?
    private var started = ContinuousClock.now

    func begin(_ opening: String) {
        started = .now
        seconds = nil
        manualExpansion = nil
        steps = [opening]
    }

    func finish() {
        seconds = Int(started.duration(to: .now).components.seconds)
    }
}

struct InspectionStatusLabel: View {
    @ObservedObject var status: InspectionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var autoExpanded = false
    private var working: Bool { status.seconds == nil }
    private var expanded: Bool { status.manualExpansion ?? (working && autoExpanded) }
    private var motion: Animation? {
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                status.manualExpansion = !expanded
            } label: {
                HStack(spacing: 6) {
                    if let seconds = status.seconds {
                        Image(systemName: "checkmark.circle")
                        Text(seconds == 0 ? "Analysis complete" :
                             "Analyzed in \(seconds) \(seconds == 1 ? "second" : "seconds")")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("Analyzing capture")
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(status.steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 7) {
                            if working && index == status.steps.count - 1 {
                                ProgressView().controlSize(.mini).frame(width: 14)
                            } else {
                                Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 14)
                            }
                            Text(step.replacingOccurrences(of: "…", with: ""))
                        }
                        .font(.caption)
                        .transition(.opacity)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .animation(motion, value: expanded)
        .animation(motion, value: status.steps.count)
        .task {
            guard working else { return }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            autoExpanded = true
        }
    }
}
