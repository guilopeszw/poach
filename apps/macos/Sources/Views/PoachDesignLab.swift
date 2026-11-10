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
        case capture = "Capture", editor = "Editor", settings = "Settings", welcome = "Welcome"
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

    var body: some View {
        VStack(spacing: 0) {
            specimen.id(dataset).environment(\.poachDesignFixture, dataset.fixture)
            Divider()
            VStack(spacing: 8) {
                Picker("Surface", selection: $surface) {
                    ForEach(Surface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
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
                            onShareContext: { _, _ in "" }, onClose: {})
        case .settings:
            PoachSettingsView(storageVisible: false, captureBusy: true)
                .padding(16)
                .frame(width: width == 320 ? 320 : 440)
        case .welcome:
            PoachOnboardingView(onContinue: { surface = .capture })
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
