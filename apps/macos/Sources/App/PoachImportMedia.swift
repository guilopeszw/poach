import AppKit
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

/// Reads what ⌘V pastes on the home window: one copied image or video file, or raw image data
/// (such as a screenshot taken with ⌃⇧⌘4). Raw images are saved like Poach's own screenshots,
/// as `screenshot-<UUID>.png` in the temporary Poach folder, so storage cleanup covers them.
enum PoachPastedMedia {
    struct Failure: Error {
        let message: String
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> Result<URL, Failure> {
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.count > 1 { return .failure(Failure(message: "Paste one file at a time.")) }
        if let file = files.first {
            if let reason = PoachImportMedia.rejectionReason(for: file) { return .failure(Failure(message: reason)) }
            return .success(file)
        }
        guard let png = pngData(from: pasteboard) else {
            return .failure(Failure(message: "Copy an image or video first, then paste."))
        }
        do {
            return .success(try save(png))
        } catch {
            return .failure(Failure(message: "Poach couldn't save the pasted image."))
        }
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func save(_ png: Data) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "Poach", directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "screenshot-\(UUID().uuidString).png")
        guard fm.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return url
    }
}
