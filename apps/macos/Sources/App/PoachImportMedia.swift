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
