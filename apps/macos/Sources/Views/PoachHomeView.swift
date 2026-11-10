import SwiftUI
import UniformTypeIdentifiers

struct PoachHomeView: View {
    private enum CaptureType: String, CaseIterable {
        case record = "Record"
        case screenshot = "Screenshot"

        var symbol: String {
            self == .record ? "record.circle" : "camera"
        }
    }

    let icon: NSImage
    let isWorking: Bool
    var workingTitle: String = "Preparing your capture…"
    let isRecording: Bool
    let elapsedSeconds: Int
    @Binding var captureMode: PoachCaptureMode
    let onStartRecording: () -> Void
    var onScreenshot: () -> Void = {}
    let onStopRecording: () -> Void
    let onLoadMedia: () -> Void

    let onDropMedia: (URL) -> Void
    let loadingFile: URL?
    var layoutWidth: CGFloat?
    @ObservedObject var status: InspectionStatus
    @State private var targeted = false
    @State private var hovering = false
    @State private var dropError: String?
    @State private var dropRejectionPhase = 0.0
    private var highlightDropZone: Bool { (hovering || targeted) && !isWorking && !isRecording }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settings = false
    @State private var captureType = CaptureType.record

    private var primaryTitle: String {
        if isRecording { return "Stop and inspect · \(clock(elapsedSeconds)) / 0:30" }
        if isWorking && loadingFile == nil { return workingTitle }
        return captureType == .screenshot ? "Take screenshot…" : "Record…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header
                Spacer()
                PoachSegments(label: "Poach", selection: $settings, choices: [(false, "Capture"), (true, "Settings")], underlined: true)
                    .frame(width: 144)
            }
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) { Divider() }
            Group {
                if settings {
                    PoachSettingsView(captureBusy: isWorking || isRecording)
                } else {
                    captureControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: settings)
        }
        .padding(16)
        .frame(width: layoutWidth ?? Self.windowSize.width, height: Self.windowSize.height, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(PoachPalette.canvas)
        .tint(PoachPalette.ink)
        .preferredColorScheme(.light)
    }

    static var windowSize: NSSize {
        NSSize(width: min(440, (NSScreen.main?.visibleFrame.width ?? 800) - 32), height: 320)
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture the screen")
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            PoachSegments(label: "Capture type", selection: $captureType,
                          choices: CaptureType.allCases.map { ($0, $0.rawValue) },
                          symbol: { $0.symbol })
                .frame(width: 210)
                .disabled(isWorking || isRecording)

            PoachSegments(label: "Capture source", selection: $captureMode,
                          choices: PoachCaptureMode.allCases.map { ($0, $0.title) })
                .disabled(isWorking || isRecording)

            Button(action: performCaptureAction) {
                Label(primaryTitle, systemImage: isRecording ? "stop.fill" : captureType.symbol)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PoachActionStyle(fill: isRecording ? .red : PoachPalette.ink, foreground: .white))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking)

            if let loadingFile {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loadingFile.lastPathComponent).font(.headline).lineLimit(1)
                        InspectionStatusLabel(status: status, allowsExpansion: false)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
            } else {
                Button {
                    dropError = nil
                    onLoadMedia()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(PoachPalette.inset, in: RoundedRectangle(cornerRadius: 9))
                            .rotationEffect(.degrees(targeted && !reduceMotion ? -8 : 0))
                            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.35), value: targeted)
                            .modifier(DropRejectionShake(phase: reduceMotion ? 0 : dropRejectionPhase))
                            .accessibilityHidden(true)
                        Text("Drop an image or video")
                            .font(.system(size: 13, weight: .semibold))
                        Text(dropError ?? "or click to browse")
                            .font(.caption)
                            .foregroundStyle(dropError == nil ? Color.secondary : PoachPalette.errorText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(highlightDropZone ? PoachPalette.inset : PoachPalette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(highlightDropZone ? PoachPalette.ink : PoachPalette.outline)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Open an image or video")
                .accessibilityHint(dropError ?? "Choose a file or drop it here")
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: highlightDropZone)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !isWorking, !isRecording else { return false }
                guard providers.count == 1, let file = providers.first else {
                    rejectDrop("Drop one file at a time.")
                    return false
                }
                _ = file.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    let error: String?
                    if let url {
                        error = PoachImportMedia.rejectionReason(for: url)
                    } else {
                        error = "Poach couldn't read this file."
                    }
                    DispatchQueue.main.async {
                        if let error {
                            rejectDrop(error)
                        } else if let url {
                            dropError = nil
                            onDropMedia(url)
                        }
                    }
                }
                return true
            }
            .disabled(isWorking || isRecording)
            }
        }
    }

    private func rejectDrop(_ message: String) {
        dropError = message
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.34)) {
            dropRejectionPhase += 1
        }
    }

    private func performCaptureAction() {
        if isRecording { onStopRecording() }
        else if captureType == .screenshot { onScreenshot() }
        else { onStartRecording() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text("Poach").font(.headline)
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private nonisolated struct DropRejectionShake: ViewModifier, Animatable {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        let progress = phase - floor(phase)
        let swing = sin(progress * 6 * .pi) * (1 - progress)
        content
            .rotationEffect(.degrees(-12 * swing))
            .offset(x: 6 * swing)
    }
}

struct PoachRecordingStatusView: View {
    let elapsedSeconds: Int
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Recording screen").font(.system(size: 13, weight: .semibold))
                .accessibilityValue("\(elapsedSeconds) of 30 seconds")
            Spacer(minLength: 4)
            Button("Stop") { onStop() }
                .buttonStyle(PoachActionStyle(fill: .red, foreground: .white))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 260)
        .background(PoachPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
        .tint(PoachPalette.ink)
        .preferredColorScheme(.light)
    }
}
