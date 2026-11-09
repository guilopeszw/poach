import SwiftUI
import UniformTypeIdentifiers

struct PoachHomeView: View {
    let icon: NSImage
    let isWorking: Bool
    var workingTitle: String = "Preparing your capture…"
    let isRecording: Bool
    let elapsedSeconds: Int
    @Binding var captureMode: PoachCaptureMode
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onLoadMedia: () -> Void

    let onDropMedia: (URL) -> Void
    let loadingFile: URL?
    var layoutWidth: CGFloat?
    @ObservedObject var status: InspectionStatus
    @State private var targeted = false
    @State private var hovering = false
    private var highlightDropZone: Bool { (hovering || targeted) && !isWorking && !isRecording }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settings = false

    private var primaryTitle: String {
        if isRecording { return "Stop and inspect · \(clock(elapsedSeconds)) / 0:30" }
        if isWorking && loadingFile == nil { return workingTitle }
        switch captureMode {
        case .selectedPortion: return "Select an area…"
        case .fullScreen: return "Choose a screen…"
        case .window: return "Choose a window…"
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Record the screen")
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            PoachSegments(label: "Recording mode", selection: $captureMode,
                          choices: PoachCaptureMode.allCases.map { ($0, $0.title) })
            .disabled(isWorking || isRecording)

            Button(action: isRecording ? onStopRecording : onStartRecording) {
                Label(primaryTitle, systemImage: isRecording ? "stop.fill" : "record.circle")
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
                        InspectionStatusLabel(status: status)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
            } else {
                Button(action: onLoadMedia) {
                    HStack(spacing: 11) {
                        Image(systemName: targeted ? "arrow.down.to.line" : "tray")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 29)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(targeted ? "Release to open" : "Open a file")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Drop an image or video here").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(12)
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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: highlightDropZone)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !isWorking, !isRecording, providers.count == 1, let file = providers.first else { return false }
                _ = file.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                    DispatchQueue.main.async { onDropMedia(url) }
                }
                return true
            }
            .disabled(isWorking || isRecording)
            }
        }
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
