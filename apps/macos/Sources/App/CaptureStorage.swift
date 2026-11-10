import Foundation
import Darwin

@MainActor
enum CaptureStorage {
    static var openPaths: [String] = []

    struct Usage {
        var total: Int64 = 0
        var unused: Int64 = 0
        var removable: [URL] = []
    }

    private struct Handoff: Decodable {
        let briefId: UUID?
        let sharedAt: Double
        let evidence: Evidence
        struct Evidence: Decodable {
            let sourcePath: String
            let keyframes: [Frame]
            struct Frame: Decodable { let imagePath: String }
        }
    }

    static func archiveActiveHandoff(_ active: URL, in archive: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: active)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        guard let handoff = try? JSONDecoder().decode(Handoff.self, from: data),
              let id = handoff.briefId,
              Date().timeIntervalSince1970 - handoff.sharedAt <= 86400 else { return }

        let destination = archive.appendingPathComponent("\(id.uuidString.lowercased()).json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func scan(temp: URL = FileManager.default.temporaryDirectory,
                     cache: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Poach")) throws -> Usage {
        let fm = FileManager.default
        var paths = openPaths
        var briefFiles = [cache.appendingPathComponent("active-brief.json")]
        let archive = cache.appendingPathComponent("briefs", isDirectory: true)
        do {
            briefFiles += try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No archived briefs exist yet.
        }
        for file in briefFiles {
            let info: URLResourceValues
            do {
                info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // No capture has been shared, or a brief expired during the scan.
                continue
            }
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            do {
                let brief = try JSONDecoder().decode(Handoff.self, from: Data(contentsOf: file))
                if Date().timeIntervalSince1970 - brief.sharedAt <= 86400 {
                    paths += [brief.evidence.sourcePath] + brief.evidence.keyframes.map(\.imagePath)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A brief may expire or be removed while storage is being scanned.
            }
        }
        let protected = Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var usage = Usage()
        for dir in try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) {
            let pattern: String
            switch dir.lastPathComponent {
            case "Poach":
                let id = #"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"#
                pattern = #"^(?:capture-\#(id)\.mov|screenshot-\#(id)\.png)$"#
            case let name where name.range(of: "^poach-recording-[a-zA-Z0-9]{6}$", options: .regularExpression) != nil:
                pattern = #"^recording\.mp4$"#
            case let name where name.range(of: "^poach-[a-zA-Z0-9]{6}$", options: .regularExpression) != nil:
                pattern = #"^[a-zA-Z0-9_-]{1,48}-(image|(start|peak|settled)-[0-9]+ms)\.png$"#
            default: continue
            }
            let directory = try dir.resourceValues(forKeys: keys)
            guard directory.isDirectory == true, directory.isSymbolicLink != true else { continue }
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) {
                guard file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil else { continue }
                let info = try file.resourceValues(forKeys: keys)
                guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                let size = Int64(info.fileSize ?? 0)
                usage.total += size
                if !protected.contains(file.resolvingSymlinksInPath().path) {
                    usage.unused += size
                    usage.removable.append(file)
                }
            }
        }
        return usage
    }

    static func clear(temp: URL = FileManager.default.temporaryDirectory,
                      cache: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Poach")) throws {
        let files = try scan(temp: temp, cache: cache).removable
        for file in files { try FileManager.default.removeItem(at: file) }
        // rmdir only removes empty folders, even if a new file appeared during cleanup.
        for dir in Set(files.map { $0.deletingLastPathComponent() }) where dir.lastPathComponent != "Poach" {
            _ = rmdir(dir.path)
        }
    }
}
