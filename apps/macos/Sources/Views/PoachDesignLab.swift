#if DEBUG
import AppKit
import SwiftUI

struct PoachDesignFixture {
    let comments: [CaptureComment]
    let instructions: String
    let connected: Bool
}

private struct PoachDesignFixtureKey: EnvironmentKey {
    static let defaultValue: PoachDesignFixture? = nil
}

extension EnvironmentValues {
    var poachDesignFixture: PoachDesignFixture? {
        get { self[PoachDesignFixtureKey.self] }
        set { self[PoachDesignFixtureKey.self] = newValue }
    }
}

struct PoachDesignLab: View {
    private enum Surface: String, CaseIterable {
        case capture = "Capture", editor = "Editor", settings = "Settings", welcome = "Welcome", pill = "Pill", drop = "Drop"
    }

    private enum Dataset: String, CaseIterable {
        case demo = "Demo data", worst = "Worst case", empty = "Empty", one = "One", many = "1,284 notes"

        var fixture: PoachDesignFixture {
            let notes = [
                "Confirmar envio: mantenha o botão no lugar enquanto a confirmação aparece.",
                "Đặng Thị Ngọc Hân 👩🏽‍💻 — giữ trạng thái sau khi thả tệp.",
                "احتفظ بمؤشر التحميل حتى تكتمل العملية.",
                "Compare https://example.com/workspaces/acme/projects/q3-launch/design-review?tab=comments&filter=unresolved with the final confirmation."
            ]
            switch self {
            case .demo:
                return .init(comments: [.init(time: 1.2, text: "The file card settles here.")],
                             instructions: "Keep the drop confirmation visible.", connected: true)
            case .worst:
                return .init(comments: notes.enumerated().map { .init(time: 29 + Double($0.offset) / 10, text: $0.element) },
                             instructions: Array(repeating: notes.joined(separator: "\n"), count: 12).joined(separator: "\n\n"),
                             connected: false)
            case .empty:
                return .init(comments: [], instructions: "", connected: false)
            case .one:
                return .init(comments: [.init(time: 0, text: "王")], instructions: "Keep the icon.", connected: true)
            case .many:
                return .init(comments: (0..<1_284).map { .init(time: Double($0) / 1_283 * 29.99, text: "Review note \($0 + 1)") },
                             instructions: "Compare the recorded states.", connected: true)
            }
        }
    }

    @State private var surface = Surface(rawValue: UserDefaults.standard.string(forKey: "poachDesignSurface") ?? "") ?? .editor
    @State private var dataset = Dataset(rawValue: UserDefaults.standard.string(forKey: "poachDesignDataset") ?? "") ?? .demo
    @State private var width = Int(UserDefaults.standard.string(forKey: "poachDesignWidth") ?? "") ?? 800
    private let heightLimit = UserDefaults.standard.string(forKey: "poachDesignHeight").flatMap(Int.init)
    @State private var captureType = PoachCaptureType.record
    @State private var homeTab = PoachHomeView.Tab.capture
    @State private var mode = PoachCaptureMode.selectedPortion
    @StateObject private var status = InspectionStatus()
    @State private var pillTimerExpanded = false
    @State private var pillTimerOpen = true
    /// Alternates between resting and pressed, to watch the lens lift out of the pill.
    @State private var pillLensPress: CGFloat?
    /// Re-keys the drop specimen so the area pill's entrance replays.
    @State private var dropReplay = 0
    @AppStorage(PoachCaptureTimer.storageKey) private var labTimerSeconds = PoachCaptureTimer.off.rawValue
    @AppStorage(CapturePillStyle.storageKey) private var pillStyle = CapturePillStyle.custom.rawValue

    var body: some View {
        VStack(spacing: 0) {
            specimen.id(dataset).environment(\.poachDesignFixture, dataset.fixture)
            Divider()
            VStack(spacing: 8) {
                Picker("Surface", selection: $surface) {
                    ForEach(Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if surface == .pill {
                    Picker("Pill glass", selection: $pillStyle) {
                        ForEach(CapturePillStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                }
                Picker("Fixture", selection: $dataset) {
                    ForEach(Dataset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Editor width", selection: $width) {
                    Text("320 pt").tag(320)
                    Text("800 pt").tag(800)
                    Text("1,200 pt").tag(1_200)
                }.pickerStyle(.segmented)
            }
            .padding(10)
            .frame(width: 480)
            .background(PoachPalette.panel)
        }
        .preferredColorScheme(.light)
        .onAppear {
            // Launched from a shell, the lab would otherwise stay inactive and show inactive-window colours.
            NSApp.activate()
        }
        .onAppear {
            status.begin("Reading recording…")
            status.finish()
        }
    }

    @ViewBuilder
    private var specimen: some View {
        switch surface {
        case .capture:
            PoachHomeView(icon: NSApp.applicationIconImage, isWorking: dataset == .worst,
                          isRecording: false, elapsedSeconds: 0, captureMode: $mode,
                          captureType: $captureType, tab: $homeTab,
                          onStartRecording: {}, onStopRecording: {}, onLoadMedia: {}, onDropMedia: { _ in },
                          loadingFile: dataset == .worst ? videoURL : nil, layoutWidth: width == 320 ? 320 : nil,
                          status: status)
        case .editor:
            FloatingHUDView(sourceURL: videoURL, isVideo: true, availableWidth: CGFloat(width),
                            availableHeight: heightLimit.map(CGFloat.init) ?? ((NSScreen.main?.visibleFrame.height ?? 800) - 56),
                            palette: swatches, pointerTrace: nil,
                            onShareContext: { _, _, _, _ in "" }, onClose: {})
        case .settings:
            PoachSettingsView(storageVisible: false, captureBusy: true)
                .padding(16)
                .frame(width: width == 320 ? 320 : 440)
        case .welcome:
            PoachOnboardingView(onContinue: { surface = .capture })
        case .drop:
            dropSpecimen
        case .pill:
            // A busy backdrop, so the glass's refraction and tint are visible.
            ZStack {
                // Bright on top, dark (like a terminal) below.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.orange, .pink, .indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Color(red: 0.1, green: 0.1, blue: 0.12)
                }
                VStack(spacing: 6) {
                    ForEach(0..<7) { row in
                        Text(String(repeating: "Poach glass  ", count: 6))
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(row.isMultiple(of: 2) ? .white : .yellow)
                            .fixedSize()
                    }
                }
                VStack(spacing: 4) {
                    CapturePill(phase: .selecting(canStart: true), timerExpanded: $pillTimerExpanded,
                                onPrimary: {}, onCancel: {})
                    // The open timer in light and dark; `.custom` forces light, `.unified` follows the scheme.
                    HStack(spacing: 24) {
                        CapturePill(phase: .selecting(canStart: true), screenshot: true, timerExpanded: $pillTimerOpen,
                                    onPrimary: {}, onCancel: {})
                        // Dark, and wrapped in the area overlay's drop-in like the real selection.
                        overlayPill { opacity in
                            CapturePill(phase: .selecting(canStart: true), screenshot: true, timerExpanded: $pillTimerOpen,
                                        onPrimary: {}, onCancel: {}, controlsOpacity: opacity)
                        }
                        .environment(\.colorScheme, .dark)
                    }
                    // The lens pressed over Off (past the pill's left edge) and released every 2 s, with the press spring, in light and dark.
                    HStack(spacing: 24) {
                        CapturePill(phase: .selecting(canStart: true), timerExpanded: .constant(true),
                                    onPrimary: {}, onCancel: {})
                        overlayPill { opacity in
                            CapturePill(phase: .selecting(canStart: true), timerExpanded: .constant(true),
                                        onPrimary: {}, onCancel: {}, controlsOpacity: opacity)
                        }
                        .environment(\.colorScheme, .dark)
                    }
                    .environment(\.timerLensPreviewX, pillLensPress)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.78)) {
                                // Like a real press, the option under the lens becomes the choice at once.
                                let press = pillLensPress == nil
                                pillLensPress = press ? 10 : nil
                                labTimerSeconds = press ? PoachCaptureTimer.off.rawValue : PoachCaptureTimer.ten.rawValue
                            }
                        }
                    }
                    CapturePill(phase: .recording(elapsed: 12, limit: 30), timerExpanded: .constant(false),
                                onPrimary: {}, onCancel: {})
                }
            }
            .frame(width: 480, height: 360)
            .clipped()
        }
    }

    /// A pill inside `CapturePillDropIn`, sized like the area pill's panel, so the lab shows the
    /// same wrapper (and any clipping it adds) as the real selection overlay.
    private func overlayPill<Pill: View>(_ pill: @escaping (Double) -> Pill) -> some View {
        let frame = CGRect(x: CapturePillLayout.panelMargin, y: CapturePillLayout.panelMargin,
                           width: CapturePillLayout.size.width, height: CapturePillLayout.size.height)
        return CapturePillDropIn(origin: CGPoint(x: frame.midX, y: 0), frame: frame, pill: pill)
            .frame(width: CapturePillLayout.panelSize.width, height: CapturePillLayout.panelSize.height)
    }

    /// The area pill's entrance under a selection outline, replayed every 2 s.
    private var dropSpecimen: some View {
        let size = CGSize(width: 480, height: 360)
        let area = CGRect(x: 90, y: 50, width: 300, height: 180)
        let frame = CaptureTargetGeometry.attachedPillFrame(for: area, pillSize: CapturePillLayout.size,
                                                             in: CGRect(origin: .zero, size: size))
        let origin = CGPoint(x: frame.midX, y: area.maxY)
        let radius = CapturePillLayout.areaCornerRadius(for: area)
        let glass: Bool = { if #available(macOS 26.0, *) { true } else { false } }()
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.orange, .pink, .indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 0.1, green: 0.1, blue: 0.12))
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            // The selection overlay's dimming around the rounded area.
            Canvas { context, canvas in
                var mask = Path(CGRect(origin: .zero, size: canvas))
                mask.addPath(Path(roundedRect: area, cornerRadius: radius, style: .continuous))
                context.fill(mask, with: .color(.black.opacity(0.48)), style: FillStyle(eoFill: true))
            }
            if !glass {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white, lineWidth: 2)
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
            }
            CapturePillDropIn(origin: origin, frame: frame, outline: glass ? area : nil) { opacity in
                CapturePill(phase: .selecting(canStart: true), timerExpanded: .constant(false),
                            onPrimary: {}, onCancel: {}, controlsOpacity: opacity)
            }
            .id(dropReplay)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                dropReplay += 1
            }
        }
    }

    private var videoURL: URL {
        let key = dataset == .worst ? "poachDesignWorstVideo" : "poachDesignVideo"
        let path = UserDefaults.standard.string(forKey: key) ?? "/tmp/Poach Design Lab.mov"
        return URL(fileURLWithPath: path)
    }

    private var swatches: [HUDPaletteToken] {
        ["F5F3EE", "161715", "D1704E", "4479B4", "687B54", "6F5478"]
            .prefix(dataset == .empty ? 0 : dataset == .one ? 1 : 6)
            .compactMap { hex in
                guard let rgb = Int(hex, radix: 16) else { return nil }
                return HUDPaletteToken(hex: "#" + hex, color: Color(
                    red: Double((rgb >> 16) & 255) / 255,
                    green: Double((rgb >> 8) & 255) / 255,
                    blue: Double(rgb & 255) / 255
                ))
            }
    }
}
#endif
