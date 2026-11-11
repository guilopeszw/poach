import SwiftUI
import UniformTypeIdentifiers

enum PoachCaptureType: String, CaseIterable {
    case record = "Record"
    case screenshot = "Screenshot"

    var symbol: String {
        self == .record ? "record.circle" : "camera"
    }
}

struct PoachHomeView: View {
    enum Tab: Int { case capture, favorites, settings }

    let icon: NSImage
    let isWorking: Bool
    var workingTitle: String = "Preparing your capture…"
    let isRecording: Bool
    let elapsedSeconds: Int
    @Binding var captureMode: PoachCaptureMode
    @Binding var captureType: PoachCaptureType
    @Binding var tab: Tab
    let onStartRecording: () -> Void
    var onScreenshot: () -> Void = {}
    var onCancelSelection: (() -> Void)?
    let onStopRecording: () -> Void
    let onLoadMedia: () -> Void

    let onDropMedia: (URL) -> Void
    let loadingFile: URL?
    var layoutWidth: CGFloat?
    @ObservedObject var status: InspectionStatus
    @State private var targeted = false
    @State private var dropError: String?
    @State private var dropRejectionPhase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tabSlideOffset: CGFloat = 0

    private var primaryTitle: String {
        if onCancelSelection != nil { return "Cancel selection" }
        if isRecording { return "Stop and inspect · \(clock(elapsedSeconds)) / 0:30" }
        if isWorking && loadingFile == nil { return workingTitle }
        return captureType == .screenshot ? "Take screenshot" : "Record"
    }

    private var primaryFill: Color {
        if onCancelSelection != nil { return PoachPalette.ink }
        if isRecording || captureType == .record { return PoachPalette.recordingRed }
        return PoachPalette.cobalt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                header
                Spacer(minLength: 8)
                PoachSegments(label: "Poach", selection: tabSelection,
                              choices: [(.capture, "Capture"), (.favorites, "Favorites"), (.settings, "Settings")],
                              underlined: true)
                    .frame(maxWidth: 214)
            }
            .padding(.bottom, 5)
            .overlay(alignment: .bottom) { Divider() }
            ZStack(alignment: .topLeading) {
                tabContent
                    .id(tab)
                    .transition(tabTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: tab)
        }
        .padding(16)
        .frame(width: layoutWidth ?? Self.windowSize.width, height: Self.windowSize.height, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(PoachPalette.canvas)
        .tint(PoachPalette.ink)
        .preferredColorScheme(.light)
    }

    private var tabSelection: Binding<Tab> {
        Binding(get: { tab }, set: { selectTab($0) })
    }

    private var tabTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .offset(x: tab == .capture ? -24 : tabSlideOffset).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .capture: captureControls
        case .favorites: PoachFavoritesView()
        case .settings: PoachSettingsView(captureBusy: isWorking || isRecording)
        }
    }

    private func selectTab(_ next: Tab) {
        guard next != tab else { return }
        tabSlideOffset = next.rawValue > tab.rawValue ? 24 : -24
        tab = next
    }

    static var windowSize: NSSize {
        NSSize(width: min(440, (NSScreen.main?.visibleFrame.width ?? 800) - 32), height: 320)
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    captureTitle
                    Spacer(minLength: 0)
                    captureTypePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    captureTitle
                    captureTypePicker
                }
            }

            HStack(spacing: 8) {
                ForEach(PoachCaptureMode.allCases) { sourceTile($0) }
            }
            .disabled(isWorking || isRecording)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Capture source")

            Button(action: performCaptureAction) {
                HStack(spacing: 8) {
                    Label(primaryTitle, systemImage: onCancelSelection != nil ? "xmark" : isRecording ? "stop.fill" : captureType.symbol)
                        .lineLimit(1)
                    if showsShortcutHint {
                        Text("⌘⇧P")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.72)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PoachActionStyle(fill: primaryFill, foreground: .white, height: 38))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking && onCancelSelection == nil)
            .help(showsShortcutHint ? "Press ⌘⇧P anywhere to record a screen area" : "")

            Spacer(minLength: 0)

            if let loadingFile {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loadingFile.lastPathComponent).font(.headline).lineLimit(1)
                        InspectionStatusLabel(status: status, allowsExpansion: false)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .contain)
            } else {
                importFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .overlay { if showsDropTarget { dropTarget.transition(.opacity) } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsDropTarget)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: receiveDrop)
    }

    private var captureTitle: some View {
        Text("Capture the screen")
            .font(.system(size: 19, weight: .semibold))
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var captureTypePicker: some View {
        PoachSegments(label: "Capture type", selection: $captureType,
                      choices: PoachCaptureType.allCases.map { ($0, $0.rawValue) },
                      symbol: { $0.symbol })
            .frame(width: 204)
            .disabled(isWorking || isRecording)
    }

    /// ⌘⇧P always records a screen area, so the hint only shows when the button does the same.
    private var showsShortcutHint: Bool {
        onCancelSelection == nil && !isRecording && !isWorking
            && captureType == .record && captureMode == .selectedPortion
    }

    private var showsDropTarget: Bool { targeted && !isWorking && !isRecording }

    private func sourceSymbol(_ mode: PoachCaptureMode) -> String {
        switch mode {
        case .selectedPortion: "rectangle.dashed"
        case .fullScreen: "display"
        case .window: "macwindow"
        }
    }

    private func sourceTile(_ mode: PoachCaptureMode) -> some View {
        let selected = captureMode == mode
        return Button {
            captureMode = mode
        } label: {
            VStack(spacing: 8) {
                Image(systemName: sourceSymbol(mode))
                    .font(.system(size: 21, weight: selected ? .medium : .regular))
                    .frame(height: 24)
                    .accessibilityHidden(true)
                Text(mode.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(PoachPalette.ink.opacity(selected ? 1 : 0.72))
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(selected ? Color.white : PoachPalette.inset.opacity(0.55), in: .poach(PoachRadius.control))
            .overlay {
                if selected {
                    RoundedRectangle.poach(PoachRadius.control)
                        .strokeBorder(PoachPalette.ink, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.poach(PoachRadius.control))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One quiet line replaces the old drop box: the whole tab accepts a dropped file.
    private var importFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.and.arrow.down")
                .modifier(DropRejectionShake(phase: reduceMotion ? 0 : dropRejectionPhase))
                .accessibilityHidden(true)
            if let dropError {
                Text(dropError).foregroundStyle(PoachPalette.errorText).lineLimit(2)
            } else {
                Text("Drop an image or video here, or")
            }
            Button {
                dropError = nil
                onLoadMedia()
            } label: {
                Text(dropError == nil ? "choose a file" : "Choose a file").underline()
            }
            .buttonStyle(.link)
            .fixedSize()
            .accessibilityLabel("Open an image or video")
            .accessibilityHint("Choose a file, or drop one on this window")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .disabled(isWorking || isRecording)
    }

    private var dropTarget: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 22, weight: .medium))
            Text("Drop to inspect")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(PoachPalette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PoachPalette.canvas.opacity(0.94), in: .poach(PoachRadius.container))
        .overlay {
            RoundedRectangle.poach(PoachRadius.container)
                .strokeBorder(PoachPalette.ink, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
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

    private func rejectDrop(_ message: String) {
        dropError = message
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.34)) {
            dropRejectionPhase += 1
        }
    }

    private func performCaptureAction() {
        if let onCancelSelection { onCancelSelection() }
        else if isRecording { onStopRecording() }
        else if captureType == .screenshot { onScreenshot() }
        else { onStartRecording() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text("Poach").font(.headline).lineLimit(1).fixedSize()
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct DropRejectionShake: Animatable {
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }
}

extension DropRejectionShake: ViewModifier {
    func body(content: Content) -> some View {
        let progress = phase - floor(phase)
        let swing = sin(progress * 6 * .pi) * (1 - progress)
        content
            .rotationEffect(.degrees(-12 * swing))
            .offset(x: 6 * swing)
    }
}

