import SwiftUI
import AVFoundation

struct HUDPaletteToken: Identifiable {
    let hex: String
    let color: Color
    var id: String { hex }
}

struct FloatingHUDView: View {
    let sourceURL: URL
    let isVideo: Bool
    @State private var player: AVPlayer?
    #if DEBUG
    @Environment(\.poachDesignFixture) private var designFixture
    #endif
    @State private var comments: [CaptureComment] = []
    @State private var commentDraft = ""
    @State private var commentAnchor: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var commentsOpen = false
    @State private var sidebarReserved = false
    @State private var sidebarRevealed = false
    private let sidebarMotionDuration = Duration.milliseconds(220)
    private let sidebarFullWidth: CGFloat = 230
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    private var overlaysComments: Bool { availableWidth < 600 }
    private var editorWidth: CGFloat {
        min(550, availableWidth - (isVideo && !overlaysComments ? sidebarFullWidth : 0))
    }
    private var commentWidth: CGFloat { overlaysComments ? min(260, editorWidth - 42) : sidebarFullWidth }
    private var commentsLayout: CommentsLayout {
        guard commentsOpen else { return .closed }
        return overlaysComments ? .drawer : .sidebar
    }
    @State private var playback = CommentPlayback()
    let palette: [HUDPaletteToken]
    let pointerTrace: PointerTrace?
    var onShareContext: (String, [InteractionAnnotation]) throws -> String
    var onSaveFavorite: ((String, String, [InteractionAnnotation]) throws -> UUID)?
    @State private var favoriteID: UUID?
    @State private var showingSaveFavorite = false
    @State private var favoriteName = ""
    @State private var favoriteError = ""
    @State private var connected = false
    @State private var showingAssistantSetup = false
    @State private var shareStatus = ""
    @State private var copyFeedback: UUID?
    @State private var context = ""
    @State private var colorOverrides: [String: Color] = [:]
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
        BriefEditorLayout(heightLimit: availableHeight - 32, isVideo: isVideo) {
            header

            Color.clear.overlay {
                if isVideo {
                    CaptureVideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let image = NSImage(contentsOf: sourceURL) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .clipped()

            VStack(alignment: .leading, spacing: 12) {
            if isVideo {
                CommentTimeline(playback: playback, comments: $comments, isOpen: $commentsOpen)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Palette").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                let columns = max(1, min(palette.count, editorWidth < 360 ? 3 : 6))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columns), spacing: 8) {
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
                Text("Change notes (optional)").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                TextEditor(text: $context)
                    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(6)
                    .overlay(alignment: .topLeading) {
                        if context.isEmpty {
                            Text("Describe any changes you’d like.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 11)
                                .padding(.top, 10)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .background(PoachPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(PoachPalette.outline, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Change notes (optional)")
                    .onChange(of: context) { shareStatus = "Changes have not been shared yet." }
            }

            Button {
                connected = Self.hasLiveConnector()
                guard connected else { return }
                copyFeedback = nil
                do {
                    let id = try onShareContext(implementationContext, annotations)
                    let message = "Use Poach MCP to call poach_read_brief with briefId \(id). Verify the returned briefId matches before using its images, pointer trace, and timestamped notes. \(pointerEvidenceGuidance) Match pointer coordinates and timestamps to the frames to identify targets. For a drag, inspect the frames after release and include visible changes through the end of the response. Use the video and notes to describe visible results, and ask if behavior is ambiguous. Recreate the recorded interaction in this project. For video details, call poach_read_moment with the same briefId and timeMs."
                    let copied = PoachHandoff.copyToClipboard(message)
                    shareStatus = copied ? "" : "Clipboard unavailable. Click Copy handoff to try again."
                    if copied { copyFeedback = UUID() }

                } catch {
                    shareStatus = "Could not share: \(error.localizedDescription)"
                }
            }
            label: {
                Label(copyFeedback == nil ? "Copy handoff to chat" : "Copied",
                      systemImage: copyFeedback == nil ? "doc.on.doc" : "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PoachActionStyle(fill: PoachPalette.ink, foreground: .white))
            .disabled(!connected)
            .task(id: copyFeedback) {
                guard copyFeedback != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copyFeedback = nil
            }
            if !connected {
                Button { showingAssistantSetup = true } label: {
                    Label("Connect Codex or Claude", systemImage: "link")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens assistant setup")
            }
            if !favoriteError.isEmpty {
                Text(favoriteError).font(.caption).foregroundStyle(PoachPalette.errorText)
            }
            if !shareStatus.isEmpty {
                Text(shareStatus).font(.caption).foregroundStyle(.secondary)
            }
            }
        }
        .padding(16)
        .frame(width: editorWidth)
        .preferredColorScheme(.light)
        .accessibilityHidden(overlaysComments && commentsOpen)
        if isVideo && !overlaysComments && sidebarReserved {
            commentSidebar(heightLimit: availableHeight)
        }
        }
        .background(PoachPalette.canvas)
        .preferredColorScheme(.light)
        .frame(width: editorWidth + (!overlaysComments && sidebarReserved ? commentWidth : 0))
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .trailing) {
            if isVideo && overlaysComments {
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(sidebarRevealed ? 0.12 : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { commentsOpen = false }
                            .accessibilityHidden(true)
                        commentSidebar(heightLimit: geometry.size.height)
                    }
                }
                .allowsHitTesting(commentsOpen)
            }
        }
        .clipped()
        .task(id: commentsLayout) {
            switch commentsLayout {
            case .sidebar where !sidebarReserved:
                sidebarReserved = true
                // Reveal after the panel has room for the sidebar.
            case .sidebar:
                revealComments(true)
            case .drawer:
                sidebarReserved = false
                revealComments(true)
            case .closed:
                revealComments(false)
                if sidebarReserved && !reduceMotion {
                    do { try await Task.sleep(for: sidebarMotionDuration) } catch { return }
                }
                guard !commentsOpen else { return }
                sidebarReserved = false
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            resizeEditorWindow(to: size)
            if sidebarReserved && commentsOpen && !sidebarRevealed {
                revealComments(true)
            }
        }
        .sheet(isPresented: $showingAssistantSetup) { AssistantSetupView() }
        .task {
            #if DEBUG
            if let designFixture {
                connected = designFixture.connected
                return
            }
            #endif
            while !Task.isCancelled {
                connected = Self.hasLiveConnector()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onAppear {
            #if DEBUG
            if let designFixture {
                comments = designFixture.comments
                context = designFixture.instructions
                commentsOpen = isVideo && !overlaysComments
            }
            #endif
            if isVideo {
                let newPlayer = AVPlayer(url: sourceURL)
                player = newPlayer
                playback.attach(newPlayer)
            }
        }
        .alert("Add to Favorites", isPresented: $showingSaveFavorite) {
            TextField("Favorite name", text: $favoriteName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveFavorite() }
                .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Keep this handoff and its reference frames for later.")
        }
        .onChange(of: comments) { shareStatus = "Changes have not been shared yet." }
        .onDisappear { playback.detach(); player = nil }
    }

    private enum CommentsLayout {
        case closed, drawer, sidebar
    }

    private func revealComments(_ reveal: Bool) {
        guard sidebarRevealed != reveal else { return }
        withAnimation(reduceMotion ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 0.22)) {
            sidebarRevealed = reveal
        }
    }

    private func resizeEditorWindow(to size: CGSize) {
        guard let panel = NSApp.windows.first(where: { $0.title == "Poach — Implementation brief" && $0.isVisible }),
              panel.contentRect(forFrameRect: panel.frame).size != size else { return }
        let frameSize = panel.frameRect(forContentRect: CGRect(origin: .zero, size: size)).size
        var frame = panel.frame
        frame.origin.y = frame.maxY - frameSize.height
        frame.size = frameSize
        if let visible = panel.screen?.visibleFrame {
            frame = fitWindowFrame(frame, in: visible)
        }
        panel.setFrame(frame, display: true)
    }

    private func commentSidebar(heightLimit: CGFloat) -> some View {
        CommentSidebar(playback: playback, comments: $comments, draft: $commentDraft,
                       anchor: $commentAnchor, heightLimit: heightLimit,
                       onClose: overlaysComments ? { commentsOpen = false } : nil)
            .frame(width: commentWidth)
            .overlay(alignment: .leading) { Divider() }
            .offset(x: sidebarRevealed ? 0 : commentWidth)
            .clipped()
            .allowsHitTesting(commentsOpen)
            .accessibilityHidden(!commentsOpen)
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
                Text(isVideo ? "Recording" : "Image")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sourceURL.lastPathComponent)
                    .accessibilityLabel(sourceURL.lastPathComponent)
            }
            Spacer(minLength: 0)
            if onSaveFavorite != nil {
                let label = favoriteID == nil ? "Add to Favorites" : "Remove from Favorites"
                Button(action: toggleFavorite) {
                    Image(systemName: favoriteID == nil ? "bookmark" : "bookmark.fill")
                }
                .buttonStyle(PoachActionStyle())
                .accessibilityLabel(label)
                .help(label)
            }
            Button("New capture") {
                player?.pause()
                onClose()
            }
            .buttonStyle(PoachActionStyle())
        }
    }

    private var annotations: [InteractionAnnotation] {
        comments.map { InteractionAnnotation(timeMs: Int(($0.time * 1_000).rounded()), text: $0.text) }
    }

    private func toggleFavorite() {
        guard let favoriteID else {
            favoriteName = ""
            showingSaveFavorite = true
            return
        }
        do {
            try PoachFavoriteStore.delete(id: favoriteID)
            self.favoriteID = nil
            favoriteError = ""
        } catch {
            favoriteError = "Couldn’t remove the favorite. \(error.localizedDescription)"
        }
    }

    private func saveFavorite() {
        do {
            favoriteID = try onSaveFavorite?(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines),
                                            implementationContext, annotations)
            favoriteError = ""
        } catch {
            favoriteError = "Couldn’t save the favorite. \(error.localizedDescription)"
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

// Measure the controls at their natural height and give the remaining space to the preview.
private struct BriefEditorLayout: Layout {
    let heightLimit: CGFloat
    let isVideo: Bool
    private let gap: CGFloat = 12

    private func heights(width: CGFloat, subviews: Subviews) -> (header: CGFloat, preview: CGFloat, controls: CGFloat) {
        let column = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(column).height
        let controls = subviews[2].sizeThatFits(column).height
        let idealPreview = isVideo ? width * 9 / 16 : min(width, 260)
        let preview = min(idealPreview, max(0, heightLimit - header - controls - 2 * gap))
        return (header, preview, controls)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 518
        let height = heights(width: width, subviews: subviews)
        return CGSize(width: width, height: height.header + height.preview + height.controls + 2 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = heights(width: bounds.width, subviews: subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height.header))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + height.header + gap), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height.preview))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - height.controls), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height.controls))
    }
}

private struct CaptureVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspect
        view.layer = videoLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let videoLayer = view.layer as? AVPlayerLayer else { return }
        if videoLayer.player !== player { videoLayer.player = player }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let videoLayer = view.layer as? AVPlayerLayer else { return }
        videoLayer.player?.pause()
        videoLayer.player = nil
    }
}
