import Foundation
import UniformTypeIdentifiers

enum PoachImportMedia {
    static let contentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .png, .jpeg, .tiff, .webP, .bmp]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func rejectionReason(for url: URL) -> String? {
        guard url.isFileURL, let info = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true else { return "Drop a local image or video file." }
        guard isImage(url) || videoExtensions.contains(url.pathExtension.lowercased()) else {
            return "Use PNG, JPEG, WebP, TIFF, BMP, MP4, or MOV."
        }
        if let size = info.fileSize, size > 512 * 1024 * 1024 {
            return "Choose a file up to 512 MiB."
        }
        return nil
    }
}

struct PoachCaptureInfo: Codable {
    let widthPx: Int
    let heightPx: Int
    var deviceScale: Double?
    let imageMaxSize: Int
    var widthPoints: Double?
    var heightPoints: Double?
}

struct PoachInspection: Codable {
    var capture: PoachCaptureInfo?

    let mediaType: String
    let sourcePath: String
    let durationMs: Int
    let keyframes: [PoachKeyframe]
    let palette: [String]
    let timing: PoachTiming
    var pointerTrace: PointerTrace?
    var annotations: [InteractionAnnotation]?
    var browserEvidence: PoachBrowserEvidence?
    var visualFontMatch: PoachFontMatch?
}

struct InteractionAnnotation: Codable {
    let timeMs: Int
    let text: String
}

struct PoachKeyframe: Codable {
    let kind: String
    let timeMs: Int
    let imagePath: String
}

struct PoachTiming: Codable {
    let durationMs: Int
    let bezier: [Double]?
    let token: String
}

enum PoachInspectionError: LocalizedError {
    case projectNotBuilt
    case nodeNotFound
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .projectNotBuilt:
            "Reinstall Poach to restore its analysis engine."
        case .nodeNotFound:
            "Poach’s bundled runtime is missing. Reinstall Poach from the release download."
        case .processFailed(let message):
            message
        }
    }
}

enum PoachInspectionRunner {
    static func inspect(videoURL: URL, isRecording: Bool = false,
                        onProgress: @escaping @MainActor @Sendable (InspectionStage) -> Void) async throws -> PoachInspection {
        guard let engine = findEngine() else { throw PoachInspectionError.projectNotBuilt }
        guard let node = findNode() else { throw PoachInspectionError.nodeNotFound }
        let entry = engine.absoluteString
        let videoPath = videoURL.path

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = node
            process.arguments = [
                "--input-type=module", "-e",
                "import { inspectImage, inspectVideo, inspectRecording } from \(Self.jsString(entry)); const inspect = /\\.(png|jpe?g|webp|tiff?|bmp)$/i.test(process.argv[1]) ? inspectImage : (process.argv[2] === 'recording' ? inspectRecording : inspectVideo); try { const result = await inspect(process.argv[1], { onProgress: stage => console.log(stage) }); process.stdout.write(JSON.stringify(result)); } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; }",
                videoPath, isRecording ? "recording" : "import",
            ]
            // Node resolves cwd during bootstrap. A checkout under Documents can
            // block there on macOS privacy checks before our script even starts.
            // All inputs and imports are absolute, so no project cwd is needed.
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = node.deletingLastPathComponent().path + ":/usr/bin:/bin"
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                var data = Data()
                for try await line in output.fileHandleForReading.bytes.lines {
                    if let stage = InspectionStage(rawValue: line) {
                        await onProgress(stage)
                    } else {
                        data.append(contentsOf: line.utf8)
                    }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let details = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw PoachInspectionError.processFailed(details?.isEmpty == false ? details! : "The analysis process exited with status \(process.terminationStatus). Check that ffmpeg and ffprobe are available.")
                }
                do {
                    return try JSONDecoder().decode(PoachInspection.self, from: data)
                } catch {
                    throw PoachInspectionError.processFailed("Poach returned an unreadable analysis result: \(error.localizedDescription)")
                }
            } catch let error as PoachInspectionError {
                throw error
            } catch {
                throw PoachInspectionError.processFailed("Poach couldn't start its analysis engine: \(error.localizedDescription)")
            }
        }.value
    }

    private static func findEngine() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appending(path: "core/dist/index.js"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    static func findNode() -> URL? {
        guard let bin = Bundle.main.resourceURL?.appending(path: "runtime/bin"),
              ["node", "ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: bin.appending(path: $0).path) })
        else { return nil }
        return bin.appending(path: "node")
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
