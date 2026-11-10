import SwiftUI

struct PoachChromeSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PoachChromeSetupContent()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(width: 430)
        .background(PoachPalette.canvas)
        .preferredColorScheme(.light)
        .onChange(of: PoachChromeBridge.shared.captureRequest) { dismiss() }
    }
}

struct PoachChromeSetupContent: View {
    @State private var copiedCode = false
    @State private var copiedFolder = false
    private let extensionFolder = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(PoachPalette.ink)
                    .frame(width: 44, height: 44)
                    .background(PoachPalette.inset, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect Chrome")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Add browser details to your Poach recordings.")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 14) {
                GridRow(alignment: .top) {
                    stepNumber(1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open Chrome extensions").fontWeight(.semibold)
                        Text("Go to chrome://extensions and turn on Developer mode.")
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow(alignment: .top) {
                    stepNumber(2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Load the Poach extension").fontWeight(.semibold)
                        if let extensionFolder {
                            Text("Click Load unpacked, then press ⌘⇧G and paste the folder path.")
                                .foregroundStyle(.secondary)
                            Button(copiedFolder ? "Path copied" : "Copy extension folder path") {
                                copiedFolder = PoachHandoff.copyToClipboard(extensionFolder.path)
                                copiedCode = false
                            }
                            .buttonStyle(PoachActionStyle())
                        } else {
                            Text("Click Load unpacked and select the Poach apps/chrome folder.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GridRow(alignment: .top) {
                    stepNumber(3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pair with Poach").fontWeight(.semibold)
                        Text("Paste the code into the Poach extension. Capture opens after pairing.")
                            .foregroundStyle(.secondary)
                        Button(copiedCode ? "Code copied" : "Copy pairing code") {
                            copiedCode = PoachHandoff.copyToClipboard(PoachChromeBridge.shared.pairingCode())
                            copiedFolder = false
                        }
                        .buttonStyle(PoachActionStyle(fill: PoachPalette.ink, foreground: .white))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(PoachPalette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(PoachPalette.outline) }

            if let error = PoachChromeBridge.shared.errorMessage {
                Text(error).font(.caption).foregroundStyle(PoachPalette.errorText)
            }

        }
    }

    private func stepNumber(_ number: Int) -> some View {
        Text(number.formatted())
            .font(.caption.weight(.semibold).monospacedDigit())
            .frame(width: 23, height: 23)
            .background(PoachPalette.inset, in: Circle())
            .accessibilityLabel("Step \(number)")
    }
}
