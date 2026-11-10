import AppKit

@MainActor
enum PoachHandoff {
    static func share(_ result: PoachInspection, context: String,
                                    annotations: [InteractionAnnotation]) throws -> String {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Poach", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var evidence = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any] ?? [:]
        evidence["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations))
        let identifier = UUID().uuidString
        let brief: [String: Any] = [
            "briefId": identifier,
            "version": 1,
            "sharedAt": Date().timeIntervalSince1970,
            "context": context,
            "instruction": "Recreate this UI in the current project. Inspect the keyframes, preserve observed behavior and colors, and treat timing estimates as approximate. Ask about ambiguous behavior.",
            "evidence": evidence
        ]
        let data = try JSONSerialization.data(withJSONObject: brief, options: [.sortedKeys])
        let archive = directory.appendingPathComponent("briefs", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path)
        let activeBrief = directory.appendingPathComponent("active-brief.json")
        try CaptureStorage.archiveActiveHandoff(activeBrief, in: archive)
        let archivedBrief = archive.appendingPathComponent("\(identifier.lowercased()).json")
        try data.write(to: archivedBrief, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivedBrief.path)
        try data.write(to: activeBrief, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeBrief.path)
        return identifier
    }

    static func copyToClipboard(_ message: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(message, forType: .string)
    }
}

enum PoachAssistant: String, CaseIterable, Identifiable {
    case codex
    case claudeCode = "claude"

    var id: Self { self }

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    private var bundleIdentifier: String {
        switch self {
        case .codex: "com.openai.codex"
        case .claudeCode: "com.anthropic.claudefordesktop"
        }
    }

    @MainActor
    var appIcon: NSImage? {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: application.path)
        icon.size = NSSize(width: 15, height: 15)
        return icon
    }

    @MainActor
    func openApp() -> Bool {
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           runningApp.isActive || runningApp.activate() {
            return true
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        return NSWorkspace.shared.open(application)
    }
}
