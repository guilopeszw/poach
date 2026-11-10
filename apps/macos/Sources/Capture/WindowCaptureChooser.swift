import AppKit
import ScreenCaptureKit
import SwiftUI

@available(macOS 15.0, *)
struct CaptureWindowChoice: Identifiable {
    let window: SCWindow
    let app: SCRunningApplication

    var id: CGWindowID { window.windowID }
    var title: String {
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled window" : title
    }
    var label: String { "\(app.applicationName), \(title)" }
}

@available(macOS 15.0, *)
@MainActor
final class WindowCaptureChooser: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var selection: CheckedContinuation<CGWindowID, Error>?

    private init(size: NSSize) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Choose an app window"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    static func choose(from choices: [CaptureWindowChoice], screenshot: Bool) async throws -> CaptureWindowChoice {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let columns = bounds.width >= 690 ? 3 : 2
        let preferredWidth: CGFloat = switch min(columns, choices.count) {
        case 1: 400
        case 2: 500
        default: 660
        }
        let width = min(bounds.width - 32, preferredWidth)
        let height = min(bounds.height - 32, choices.count > columns ? 494 : 322)
        let size = NSSize(width: width, height: height)
        let chooser = WindowCaptureChooser(size: size)
        defer {
            chooser.panel.orderOut(nil)
            chooser.panel.contentViewController = nil
        }
        let windowID = try await withCheckedThrowingContinuation { continuation in
            chooser.selection = continuation
            let hosting = NSHostingController(rootView: WindowChooserView(
                choices: choices,
                columns: min(columns, choices.count),
                actionTitle: screenshot ? "Take screenshot" : "Record",
                onSelect: { [weak chooser] in chooser?.finish($0) },
                onCancel: { [weak chooser] in chooser?.finish(nil) }
            ).frame(width: width, height: height))
            hosting.sizingOptions = []
            chooser.panel.contentViewController = hosting
            chooser.panel.setContentSize(size)
            chooser.panel.setFrameOrigin(NSPoint(x: bounds.midX - width / 2, y: bounds.midY - height / 2))
            NSApp.activate()
            chooser.panel.makeKeyAndOrderFront(nil)
        }
        guard let selected = choices.first(where: { $0.id == windowID }) else {
            throw ScreenCaptureError.selectionCancelled
        }
        return selected
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    private func finish(_ windowID: CGWindowID?) {
        guard let selection else { return }
        self.selection = nil
        if let windowID {
            selection.resume(returning: windowID)
        } else {
            selection.resume(throwing: ScreenCaptureError.selectionCancelled)
        }
    }
}

@available(macOS 15.0, *)
private struct WindowChooserView: View {
    let choices: [CaptureWindowChoice]
    let columns: Int
    let actionTitle: String
    let onSelect: (CGWindowID) -> Void
    let onCancel: () -> Void

    @State private var selected: CGWindowID?
    @FocusState private var gridFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose an app window")
                    .font(.system(size: 21, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Select a preview, then click \(actionTitle) or press Return.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(choices) { choice in
                            Button {
                                selected = choice.id
                                gridFocused = true
                            } label: {
                                WindowPreview(choice: choice, isSelected: selected == choice.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                            .accessibilityAddTraits(selected == choice.id ? .isSelected : [])
                            .id(choice.id)
                        }
                    }
                    .padding(2)
                }
                .defaultScrollAnchor(.top)
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    move(direction)
                    if let selected { scroll.scrollTo(selected) }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    if let selected { onSelect(selected) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PoachPalette.canvas)
        .tint(PoachPalette.ink)
        .preferredColorScheme(.light)
        .defaultFocus($gridFocused, true)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let current = choices.firstIndex(where: { $0.id == selected }) else {
            selected = choices.first?.id
            return
        }
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        case .up: offset = -columns
        case .down: offset = columns
        @unknown default: return
        }
        let next = current + offset
        if choices.indices.contains(next) { selected = choices[next].id }
    }
}

@available(macOS 15.0, *)
private struct WindowPreview: View {
    let choice: CaptureWindowChoice
    let isSelected: Bool
    @State private var preview: CGImage?
    @State private var attemptedPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(PoachPalette.inset)
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if attemptedPreview {
                    Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 100)
            .clipShape(.rect(cornerRadius: 7))
            .accessibilityHidden(true)

            HStack(spacing: 6) {
                if let icon = NSRunningApplication(processIdentifier: choice.app.processID)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 17, height: 17)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(choice.app.applicationName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)) }
            }
        }
        .padding(7)
        .background(isSelected ? PoachPalette.inset : PoachPalette.panel, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? PoachPalette.ink : PoachPalette.outline)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .help(choice.label)
        .task {
            guard !attemptedPreview else { return }
            let size = choice.window.frame.size
            guard size.width > 0, size.height > 0 else {
                attemptedPreview = true
                return
            }
            let scale = min(360 / size.width, 220 / size.height, 1)
            let config = SCStreamConfiguration()
            config.width = max(2, Int(size.width * scale))
            config.height = max(2, Int(size.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: choice.window)
            let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard !Task.isCancelled else { return }
            preview = image
            attemptedPreview = true
        }
    }
}
