import SwiftUI
import AVFoundation

struct CaptureComment: Identifiable, Equatable {
    let id = UUID()
    let time: Double
    let text: String
}

private func timestamp(_ seconds: Double) -> String {
    String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}

@Observable @MainActor
final class CommentPlayback {
    private(set) var time = 0.0
    private(set) var duration = 0.0
    private(set) var playing = false
    var highlighted: CaptureComment?
    private var player: AVPlayer?
    private var observer: Any?
    private var durationLoad: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var scrubbing = false
    private var resumeAfterScrub = false

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let asset = player.currentItem?.asset {
            durationLoad = Task { [weak self] in
                guard let length = try? await asset.load(.duration).seconds,
                      !Task.isCancelled, length.isFinite else { return }
                self?.duration = max(0, length)
            }
        }
    }

    private func refresh() {
        guard let player else { return }
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 {
            duration = length
        }
        let position = player.currentTime().seconds
        if !scrubbing { time = position.isFinite ? max(0, min(duration, position)) : 0 }
        playing = player.rate != 0
    }

    func pause() { player?.pause(); refresh() }

    func toggle() {
        if playing { pause(); return }
        if duration > 0 && time >= duration - 0.02 { seek(0) }
        player?.play()
        refresh()
    }

    func scrub(_ editing: Bool) {
        guard editing != scrubbing else { return }
        scrubbing = editing
        if editing {
            resumeAfterScrub = playing
            pause()
        } else {
            let target = time
            seek(target)
            if resumeAfterScrub { player?.play() }
            resumeAfterScrub = false
        }
    }

    func seek(_ seconds: Double) {
        time = max(0, min(duration, seconds))
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func highlight(_ comment: CaptureComment) {
        expiry?.cancel()
        highlighted = comment
        expiry = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            highlighted = nil
        }
    }

    func visit(_ comment: CaptureComment) {
        pause()
        seek(comment.time)
        highlight(comment)
    }

    func detach() {
        expiry?.cancel()
        durationLoad?.cancel()
        durationLoad = nil
        if let observer { player?.removeTimeObserver(observer) }
        player?.pause()
        observer = nil
        player = nil
        duration = 0
    }
}

struct CommentTimeline: View {
    private struct Marker: Identifiable {
        let x: CGFloat
        var comments: [CaptureComment]
        var id: UUID { comments[0].id }
    }

    let playback: CommentPlayback
    @Binding var comments: [CaptureComment]
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.playing ? "Pause" : "Play")
            VStack(spacing: 0) {
                Slider(value: Binding(get: { playback.time }, set: { playback.seek($0) }),
                       in: 0...max(playback.duration, 0.01), onEditingChanged: playback.scrub)
                    .accessibilityLabel("Video timeline")
                    .accessibilityValue(timestamp(playback.time))
                GeometryReader { geometry in
                    ForEach(markers(width: geometry.size.width)) { marker in
                        commentMarker(marker)
                            .position(x: marker.x, y: 9)
                    }
                    if let comment = playback.highlighted {
                        let width = min(200, geometry.size.width)
                        Text(comment.text).font(.caption).lineLimit(2)
                            .padding(6).frame(width: width)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .position(x: min(max(width / 2, markerX(comment, width: geometry.size.width)), geometry.size.width - width / 2), y: -32)
                            .allowsHitTesting(false)
                    }
                }.frame(height: comments.isEmpty ? 0 : 18)
            }
            Text(timestamp(playback.time)).font(.caption.monospacedDigit())
            Button {
                isOpen.toggle()
                if isOpen { playback.pause() }
            } label: {
                Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide comments" : "Show comments")
            .accessibilityLabel(isOpen ? "Hide comments" : "Show comments")
        }
    }

    @ViewBuilder
    private func commentMarker(_ marker: Marker) -> some View {
        if marker.comments.count == 1, let comment = marker.comments.first {
            Button { visit(comment) } label: {
                markerIcon("bubble.left.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Comment at \(timestamp(comment.time)): \(comment.text)")
        } else {
            Menu {
                ForEach(marker.comments) { comment in
                    Button("\(timestamp(comment.time))  \(comment.text)") { visit(comment) }
                }
            } label: {
                markerIcon("bubble.left.and.bubble.right.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(marker.comments.count) comments")
            .accessibilityLabel("\(marker.comments.count) comments near \(timestamp(marker.comments[0].time))")
        }
    }

    private func markerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }

    private func visit(_ comment: CaptureComment) {
        isOpen = true
        playback.visit(comment)
    }

    private func markers(width: CGFloat) -> [Marker] {
        guard playback.duration > 0 else { return [] }
        var result: [Marker] = []
        for comment in comments {
            let x = markerX(comment, width: width)
            if let previousX = result.last?.x, x - previousX < 24 {
                result[result.count - 1].comments.append(comment)
            } else {
                result.append(Marker(x: x, comments: [comment]))
            }
        }
        return result
    }

    private func markerX(_ comment: CaptureComment, width: CGFloat) -> CGFloat {
        9 + max(0, width - 18) * min(1, comment.time / max(0.01, playback.duration))
    }
}

struct CommentSidebar: View {
    let playback: CommentPlayback
    @Binding var comments: [CaptureComment]
    @Binding var draft: String
    @Binding var anchor: Double?
    var heightLimit: CGFloat = 410
    var onClose: (() -> Void)?
    @State private var hovered: UUID?
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if comments.isEmpty { Text("Comments you add appear here.").foregroundStyle(.secondary) }
                    ForEach(comments) { comment in
                        HStack(alignment: .top, spacing: 4) {
                            Button { playback.visit(comment) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(timestamp(comment.time)).font(.caption.monospacedDigit()).foregroundStyle(.tint)
                                    Text(comment.text).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(8)
                                .background(PoachPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            if hovered == comment.id {
                                Button { remove(comment) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .frame(width: 22, height: 22)
                                }
                                .accessibilityLabel("Delete comment")
                            } else {
                                Color.clear.frame(width: 22, height: 22)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = comment.id }
                            else if hovered == comment.id { hovered = nil }
                        }
                        .accessibilityAction(named: "Delete comment") { remove(comment) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.top)
            Divider()
            Text("Comment at \(timestamp(anchor ?? playback.time))").font(.caption.monospacedDigit())
            composer
            HStack {
                Button("Post comment", action: post)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let onClose {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "bubble.left.fill")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Hide comments")
                    .accessibilityLabel("Hide comments")
                }
            }
        }
        .padding(16)
        .frame(height: min(410, heightLimit))
        .background(PoachPalette.panel)
    }

    private var composer: some View {
        TextField("Write a comment…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...6)
            .padding(8)
            .background(PoachPalette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(composing ? Color.accentColor : PoachPalette.outline)
                    .allowsHitTesting(false)
            }
            .focused($composing)
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                post()
                return .handled
            }
            .onSubmit {
                guard NSApp.currentEvent?.modifierFlags.contains(.shift) != true else { return }
                post()
            }
            .onChange(of: composing) {
                if composing && draft.isEmpty { playback.pause(); anchor = playback.time }
            }
            .onChange(of: draft) {
                if draft.isEmpty { anchor = nil }
                else if anchor == nil { playback.pause(); anchor = playback.time }
            }
    }

    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let comment = CaptureComment(time: anchor ?? playback.time, text: text)
        comments.insert(comment, at: comments.firstIndex { $0.time > comment.time } ?? comments.endIndex)
        playback.visit(comment)
        draft = ""
        anchor = nil
    }

    private func remove(_ comment: CaptureComment) {
        comments.removeAll { $0.id == comment.id }
        if playback.highlighted?.id == comment.id { playback.highlighted = nil }
        hovered = nil
    }

}
