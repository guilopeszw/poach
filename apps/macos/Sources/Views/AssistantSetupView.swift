import SwiftUI
import AppKit

struct AssistantSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            PoachSettingsView()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 400)
        .background(PoachPalette.canvas)
        .preferredColorScheme(.light)
    }
}

struct MCPConnectorView: View {
    private enum Assistant: String, CaseIterable {
        case codex = "Codex"
        case claude = "Claude"
    }
    @State private var copied: Assistant?

    private var serverPath: String? {
        Bundle.main.url(forResource: "server", withExtension: "mjs")?.path
    }

    private func configuration(for assistant: Assistant) -> String? {
        guard let serverPath, let executable = PoachInspectionRunner.findNode() else { return nil }
        let node = executable.path
        let runtimePath = executable.deletingLastPathComponent().path + ":/usr/bin:/bin"
        if assistant == .codex {
            return [
                "codex mcp add poach",
                "  --env PATH=\(quote(runtimePath))",
                "  -- \(quote(node))",
                "  \(quote(serverPath))"
            ].joined(separator: " \\\n")
        }
        let config: [String: Any] = ["mcpServers": ["poach": ["command": node, "args": [serverPath], "env": ["PATH": runtimePath]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect an assistant").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(Assistant.allCases, id: \.self) { assistant in
                    Button {
                        guard let text = configuration(for: assistant) else { return }
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(text, forType: .string) ? assistant : nil
                    } label: {
                        Label("Copy \(assistant.rawValue)", systemImage: copied == assistant ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PoachActionStyle())
                    .disabled(configuration(for: assistant) == nil)
                    .help("Copy \(assistant.rawValue) MCP setup")
                    .accessibilityLabel("Copy \(assistant.rawValue) MCP")
                    .accessibilityValue(copied == assistant ? "Copied" : "")
                }
            }
        }
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = nil } catch {}
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct PoachSettingsView: View {
    var storageVisible = true
    var captureBusy = false
    @State private var usage: CaptureStorage.Usage?
    @State private var storageError: String?

    private func refreshStorage() {
        do { usage = try CaptureStorage.scan(); storageError = nil }
        catch { usage = nil; storageError = error.localizedDescription }
    }

    @AppStorage("defaultCaptureMode") private var defaultMode = PoachCaptureMode.selectedPortion.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Text("Default capture mode")
                Spacer()
                Picker("Default recording mode", selection: $defaultMode) {
                    ForEach(PoachCaptureMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.bordered)
                .menuIndicator(.visible)
                .fixedSize()
            }
            .frame(minHeight: 24)
            Divider()
            MCPConnectorView()
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Storage").font(.headline)
                    if let usage {
                        Text("\(usage.total.formatted(.byteCount(style: .file))) used · \(usage.unused.formatted(.byteCount(style: .file))) unused")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Clear unused captures") {
                    do { try CaptureStorage.clear(); refreshStorage() }
                    catch { refreshStorage(); storageError = error.localizedDescription }
                }
                .disabled(captureBusy || usage?.removable.isEmpty != false)
            }
            if let storageError { Text(storageError).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: storageVisible && !captureBusy) { if storageVisible && !captureBusy { refreshStorage() } }
    }
}
