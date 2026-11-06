import SwiftUI
import AVKit

struct HUDPaletteToken: Identifiable {
    let hex: String
    let color: Color
    var id: String { hex }
}

struct FloatingHUDView: View {
    let sourceURL: URL
    let isVideo: Bool
    @State private var player: AVPlayer?
    @State private var comments: [CaptureComment] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var commentsOpen = false
    @State private var sidebarWidth: CGFloat = 0
    private let sidebarFullWidth: CGFloat = 230
    private var editorWidth: CGFloat { min(550, (NSScreen.main?.visibleFrame.width ?? 800) - 48) }
    @State private var playback = CommentPlayback()
    let status: InspectionStatus
    let palette: [HUDPaletteToken]
    let pointerTrace: PointerTrace?
    var onShareContext: (String, [InteractionAnnotation]) throws -> String
    @State private var connected = false
    @State private var showingAssistantSetup = false
    @State private var shareStatus = ""
    @State private var context = ""
    @State private var colorOverrides: [String: Color] = [:]
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isVideo {
                CaptureVideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                CommentTimeline(playback: playback, comments: $comments, isOpen: $commentsOpen)
            } else if let image = NSImage(contentsOf: sourceURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 260)
            }

            InspectionStatusLabel(status: status)

            VStack(alignment: .leading, spacing: 9) {
                Text("Colors").font(.headline)
                HStack(spacing: 7) {
                    ForEach(palette) { token in
                        VStack(alignment: .leading, spacing: 5) {
                            ColorPicker("Replace \(token.hex)", selection: Binding(
                                get: { colorOverrides[token.hex] ?? token.color },
                                set: { colorOverrides[token.hex] = $0; shareStatus = "Changes have not been shared yet." }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            Text(hex(colorOverrides[token.hex] ?? token.color))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .contain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Instructions").font(.headline)
                TextField("What should your assistant build or change?", text: $context, axis: .vertical)
                    .lineLimit(nil)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(PoachPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(PoachPalette.outline, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Instructions")
                    .onChange(of: context) { shareStatus = "Changes have not been shared yet." }
            }

            Button("Copy handoff for chat") {
                connected = Self.hasLiveConnector()
                guard connected else { return }
                do {
                    let annotations = comments.map {
                        InteractionAnnotation(timeMs: Int(($0.time * 1_000).rounded()), text: $0.text)
                    }
                    let id = try onShareContext(implementationContext, annotations)
                    let message = "Use Poach MCP to call poach_read_brief with briefId \(id). Verify the returned briefId matches before using its images, pointer trace, and timestamped notes. \(pointerEvidenceGuidance) Match pointer coordinates and timestamps to the frames to identify targets; use the video and notes to describe visible results, and ask if behavior is ambiguous. Recreate the recorded interaction in this project. For video details, call poach_read_moment with the same briefId and timeMs."
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(message, forType: .string)
                    shareStatus = copied ? "Handoff copied." : "Clipboard unavailable. Click Copy handoff to try again."

                } catch {
                    shareStatus = "Could not share: \(error.localizedDescription)"
                }
            }
            .buttonStyle(PoachActionStyle(fill: PoachPalette.ink, foreground: .white))
            .disabled(!connected)
            if !connected {
                Button { showingAssistantSetup = true } label: {
                Label {
                    Text("Set up Poach MCP in Codex or Claude.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.yellow)
                }
                .foregroundStyle(Color(red: 0.46, green: 0.38, blue: 0.10))
                }.buttonStyle(.plain).accessibilityHint("Opens Settings")
            }
            if !shareStatus.isEmpty {
                Text(shareStatus).font(.caption).foregroundStyle(.secondary)
            }

        }
        .padding(16)
        .frame(width: editorWidth)
        .preferredColorScheme(.light)
        if isVideo && sidebarWidth > 0 {
            CommentSidebar(playback: playback, comments: $comments)
                .frame(width: sidebarFullWidth)
                .overlay(alignment: .leading) { Divider() }
                .frame(width: sidebarWidth, alignment: .leading)
                .clipped()
                .allowsHitTesting(commentsOpen)
        }
        }
        .background(PoachPalette.canvas)
        .preferredColorScheme(.light)
        .frame(width: editorWidth + sidebarWidth)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .task(id: commentsOpen) {
            let available = (NSScreen.main?.visibleFrame.width ?? 800) - 32 - editorWidth
            let target = commentsOpen ? max(0, min(sidebarFullWidth, available)) : 0
            let start = sidebarWidth
            guard target != start else { return }
            guard !reduceMotion else { sidebarWidth = target; return }
            let began = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = min(1, (CACurrentMediaTime() - began) / 0.22)
                let eased = t * t * (3 - 2 * t)
                sidebarWidth = (start + (target - start) * eased).rounded()
                if t == 1 { break }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard let panel = NSApp.windows.first(where: { $0.title == "Poach — Implementation brief" && $0.isVisible }),
                  panel.contentRect(forFrameRect: panel.frame).size != size else { return }
            let frameSize = panel.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size
            var frame = panel.frame
            if UserDefaults.standard.string(forKey: "windowEdge") != "left" {
                frame.origin.x = frame.maxX - frameSize.width
            }
            frame.origin.y += (frame.height - frameSize.height) / 2
            frame.size = frameSize
            panel.setFrame(frame, display: true)
        }
        .sheet(isPresented: $showingAssistantSetup) { AssistantSetupView() }
        .task {
            while !Task.isCancelled {
                connected = Self.hasLiveConnector()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onAppear {
            if isVideo {
                let newPlayer = AVPlayer(url: sourceURL)
                player = newPlayer
                playback.attach(newPlayer)
            }
        }
        .onChange(of: comments) { shareStatus = "Changes have not been shared yet." }
        .onDisappear { playback.detach(); player = nil }
    }

    private static func hasLiveConnector() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Poach/connections")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return false }
        return entries.contains { entry in
            guard let pid = Int32(entry.lastPathComponent), pid > 0,
                  let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) < 15 else { return false }
            return kill(pid, 0) == 0
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review your capture")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Make a brief for your assistant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("New capture") {
                player?.pause()
                onClose()
            }
            .buttonStyle(PoachActionStyle())
        }
    }

    private var implementationContext: String {
        let replacements = palette.compactMap { token -> String? in
            guard let replacement = colorOverrides[token.hex] else { return nil }
            return "Replace \(token.hex) with \(hex(replacement))."
        }
        return ([context] + comments.map { String(format: "[%.2fs] %@", $0.time, $0.text) } + replacements).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var pointerEvidenceGuidance: String {
        guard let pointerTrace, pointerTrace.available else {
            return "This media has no native pointer trace; do not assume clicks or drags that are not visible in the video or described in notes."
        }
        let hasButtonTransitions = pointerTrace.events.contains { event in
            event.kind == .down || event.kind == .up || event.kind == .drag
        }
        if hasButtonTransitions {
            return "The native pointer trace contains sampled button transitions and may provide click/drag candidates. Polling can miss or misclassify brief actions; correlate trace events with frames and notes, and do not infer an interaction's effect from the trace alone."
        }
        if pointerTrace.sampleCount > 0 {
            return "The native pointer sampler collected \(pointerTrace.sampleCount) samples, including \(pointerTrace.insideSampleCount) inside the capture bounds, but observed no button-down, button-up, or drag events. Do not claim clicks or drags; rely on visible video and notes, and ask if behavior is unclear."
        }
        return "A native pointer trace was started but collected no samples. Do not claim clicks or drags; rely on visible video and notes, and ask if behavior is unclear."
    }

    private func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

}

private struct CaptureVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
