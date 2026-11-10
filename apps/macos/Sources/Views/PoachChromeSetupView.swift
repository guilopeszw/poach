import SwiftUI

struct PoachChromeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copiedFolder = false
    private let extensionFolder = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect Chrome", systemImage: "puzzlepiece.extension")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Add browser events and animation details to your Poach recordings.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open chrome://extensions in Chrome.")
                if let extensionFolder {
                    Text("2. Turn on Developer mode and click Load unpacked. Press ⌘⇧G and paste the extension folder path.")
                    Button(copiedFolder ? "Folder path copied" : "Copy extension folder path") {
                        copiedFolder = PoachHandoff.copyToClipboard(extensionFolder.path)
                        copied = false
                    }
                    .buttonStyle(.link)
                } else {
                    Text("2. Turn on Developer mode. Click Load unpacked and select the Poach apps/chrome folder.")
                }
                Text("3. Open the Poach extension and paste your pairing code.")
            }
            .fixedSize(horizontal: false, vertical: true)

            if let error = PoachChromeBridge.shared.errorMessage {
                Text(error).font(.caption).foregroundStyle(PoachPalette.errorText)
            }

            HStack {
                Button(copied ? "Copied!" : "Copy pairing code") {
                    copied = PoachHandoff.copyToClipboard(PoachChromeBridge.shared.pairingCode())
                    copiedFolder = false
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(PoachPalette.canvas)
    }
}
