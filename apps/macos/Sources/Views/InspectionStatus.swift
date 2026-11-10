import SwiftUI

enum InspectionStage: String, CaseIterable {
    case motion, frames, palette

    var title: String {
        switch self {
        case .motion: "Finding movement"
        case .frames: "Preparing preview images"
        case .palette: "Sampling colors"
        }
    }

    static let stillImage: [Self] = [.frames, .palette]
}

@MainActor
final class InspectionStatus: ObservableObject {
    @Published private(set) var steps: [String] = []
    @Published private(set) var activeIndex = 0
    @Published private(set) var seconds: Int?
    @Published var manualExpansion: Bool?
    private var stages: [InspectionStage] = []
    private var started = ContinuousClock.now

    func begin(_ opening: String, stages: [InspectionStage] = InspectionStage.allCases) {
        started = .now
        seconds = nil
        manualExpansion = nil
        self.stages = stages
        steps = [opening] + stages.map(\.title)
        activeIndex = 0
    }

    func advance(to stage: InspectionStage) {
        guard let index = stages.firstIndex(of: stage), index + 1 > activeIndex else { return }
        activeIndex = index + 1
    }

    func finish() {
        seconds = Int(started.duration(to: .now).components.seconds)
    }
}

struct InspectionStatusLabel: View {
    @ObservedObject var status: InspectionStatus
    var allowsExpansion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var autoExpanded = false

    private var working: Bool { status.seconds == nil }
    private var expanded: Bool { allowsExpansion && (status.manualExpansion ?? (working && autoExpanded)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if allowsExpansion {
                Button {
                    status.manualExpansion = !expanded
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            } else {
                summary
            }

            if expanded {
                VStack(spacing: 6) {
                    ForEach(Array(status.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index, step)
                    }
                }
                .accessibilityElement(children: .contain)
                .transition(.opacity)
            }
        }
        .padding(allowsExpansion ? 10 : 0)
        .background {
            if allowsExpansion {
                RoundedRectangle(cornerRadius: 10)
                    .fill(PoachPalette.panel)
                    .strokeBorder(PoachPalette.outline)
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: expanded)
        .task {
            guard allowsExpansion && working else { return }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            autoExpanded = true
        }
    }

    private var summary: some View {
        HStack(spacing: 7) {
            if let seconds = status.seconds {
                Image(systemName: "checkmark.circle").accessibilityHidden(true)
                Text(seconds == 0 ? "Analysis complete" :
                    "Analyzed in \(seconds) \(seconds == 1 ? "second" : "seconds")")
            } else {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                if expanded {
                    let remaining = max(1, status.steps.count - status.activeIndex)
                    Text(remaining == 1 ? "1 step left" : "\(remaining) steps left")
                } else {
                    Text(status.steps.indices.contains(status.activeIndex) ? status.steps[status.activeIndex] : "Analyzing capture")
                }
            }
            if allowsExpansion {
                Spacer(minLength: 8)
                Image(systemName: expanded ? "minus" : "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(PoachPalette.inset, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    private func stepRow(_ index: Int, _ title: String) -> some View {
        let active = working && index == status.activeIndex
        let complete = !working || index < status.activeIndex
        return HStack(spacing: 7) {
            Group {
                if active {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: complete ? "checkmark.circle" : "circle.dashed")
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(active ? .primary : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            if active { Capsule().strokeBorder(PoachPalette.outline) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(complete ? "Complete" : active ? "In progress" : "Pending")
    }
}
