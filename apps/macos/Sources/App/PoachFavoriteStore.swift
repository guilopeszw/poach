import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum PoachFavoriteStore {
    struct Favorite: Identifiable {
        let id: UUID
        let name: String
        let coverURL: URL
    }

    private struct Record: Codable {
        let name: String
        let savedAt: Date
        let context: String
        let inspection: PoachInspection
    }

    private struct PortableHandoff: Codable {
        let version: Int
        let name: String
        let context: String
        let inspection: PoachInspection
        let images: [Data]
    }

    private enum StoreError: LocalizedError {
        case missingName
        case missingFrames
        case invalidFile
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .missingName: "Enter a name for this favorite."
            case .missingFrames: "The reference frames are unavailable."
            case .invalidFile: "Choose a valid .poach file exported by Poach."
            case .fileTooLarge: "Poach files can be up to 4 MiB."
            }
        }
    }

    private static let files = FileManager.default
    private static let root = URL.applicationSupportDirectory
        .appending(path: "Poach/Presets", directoryHint: .isDirectory)
    private static let fileByteLimit = 4 * 1024 * 1024
    private static let frameByteLimit = 256 * 1024
    private static let frameSizes = [1152, 864, 648, 486, 320, 192, 128]

    static func list() throws -> [Favorite] {
        let directories: [URL]
        do {
            directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }

        let entries = directories.compactMap { directory -> (Favorite, Date)? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let record = try? readRecord(in: directory),
                  let cover = record.inspection.keyframes.first(where: { $0.kind == "peak" })
                    ?? record.inspection.keyframes.first else { return nil }
            let favorite = Favorite(id: id, name: record.name, coverURL: directory.appending(path: cover.imagePath))
            return (favorite, record.savedAt)
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func save(name: String, result: PoachInspection, context: String,
                     annotations: [InteractionAnnotation]) throws -> UUID {
        try writeFavorite(name: name, result: result, context: context, annotations: annotations) { frame, _ in
            guard let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: frame.imagePath) as CFURL, nil) else {
                throw StoreError.missingFrames
            }
            return try compactPNG(image)
        }
    }

    static func export(_ favorite: Favorite, to url: URL) throws {
        let directory = directory(for: favorite.id)
        let record = try readRecord(in: directory)
        let frames = record.inspection.keyframes
        let images = try frames.map { frame in
            guard let image = CGImageSourceCreateWithURL(directory.appending(path: frame.imagePath) as CFURL, nil) else {
                throw StoreError.missingFrames
            }
            return try compactPNG(image)
        }
        let referenceFrames = frames.map { PoachKeyframe(kind: $0.kind, timeMs: $0.timeMs, imagePath: "") }
        let portable = PortableHandoff(version: 1, name: record.name, context: record.context,
            inspection: snapshot(record.inspection, frames: referenceFrames, annotations: record.inspection.annotations ?? []),
            images: images)
        let data = try JSONEncoder().encode(portable)
        guard data.count <= fileByteLimit else { throw StoreError.fileTooLarge }
        try data.write(to: url, options: .atomic)
    }

    static func importHandoff(from url: URL) throws {
        guard try isRegularFile(url) else { throw StoreError.invalidFile }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: fileByteLimit + 1) ?? Data()
        guard data.count <= fileByteLimit else { throw StoreError.fileTooLarge }
        guard let handoff = try? JSONDecoder().decode(PortableHandoff.self, from: data),
              handoff.version == 1,
              ["video", "image"].contains(handoff.inspection.mediaType),
              (1...3).contains(handoff.images.count),
              handoff.images.count == handoff.inspection.keyframes.count else {
            throw StoreError.invalidFile
        }
        _ = try writeFavorite(name: handoff.name, result: handoff.inspection, context: handoff.context,
                              annotations: handoff.inspection.annotations ?? []) { _, index in
            let image = handoff.images[index]
            guard image.count <= frameByteLimit,
                  let source = CGImageSourceCreateWithData(image as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let maxSide = frameSizes.first, (1...maxSide).contains(width), (1...maxSide).contains(height) else {
                throw StoreError.invalidFile
            }
            return try compactPNG(source)
        }
    }

    private static func writeFavorite(name: String, result: PoachInspection, context: String,
                                      annotations: [InteractionAnnotation],
                                      frameData: (PoachKeyframe, Int) throws -> Data) throws -> UUID {
        try result.browserEvidence?.validateComponents()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.missingName }
        guard !result.keyframes.isEmpty else { throw StoreError.missingFrames }

        try files.createDirectory(at: root, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let id = UUID()
        let staging = root.appending(path: ".\(id.uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }

        let frames = try result.keyframes.prefix(3).enumerated().map { index, frame in
            let filename = try frameFilename(frame, index: index)
            let destination = staging.appending(path: filename)
            try frameData(frame, index).write(to: destination)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return PoachKeyframe(kind: frame.kind, timeMs: frame.timeMs, imagePath: filename)
        }
        let record = Record(name: name, savedAt: .now, context: context,
                            inspection: snapshot(result, frames: frames, annotations: annotations))
        let metadata = staging.appending(path: "preset.json")
        try JSONEncoder().encode(record).write(to: metadata)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        try files.moveItem(at: staging, to: directory(for: id))
        return id
    }

    static func delete(id: UUID) throws {
        try files.removeItem(at: directory(for: id))
    }

    static func prepareHandoff(_ favorite: Favorite) throws
        -> (result: PoachInspection, context: String, annotations: [InteractionAnnotation]) {
        let directory = directory(for: favorite.id)
        let record = try readRecord(in: directory)
        let temporary = try makeHandoffDirectory()
        do {
            let frames = try record.inspection.keyframes.map { frame in
                let source = directory.appending(path: frame.imagePath)
                let destination = temporary.appending(path: frame.imagePath)
                do {
                    try files.linkItem(at: source, to: destination)
                } catch {
                    // A handoff can live on a different volume from the favorite.
                    try files.copyItem(at: source, to: destination)
                }
                return PoachKeyframe(kind: frame.kind, timeMs: frame.timeMs, imagePath: destination.path)
            }
            let annotations = record.inspection.annotations ?? []
            return (snapshot(record.inspection, frames: frames, annotations: annotations), record.context, annotations)
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    private static func readRecord(in directory: URL) throws -> Record {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else { throw StoreError.missingFrames }
        let metadata = directory.appending(path: "preset.json")
        guard try isRegularFile(metadata) else { throw StoreError.missingFrames }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: metadata))
        let frames = record.inspection.keyframes
        guard (1...3).contains(frames.count) else { throw StoreError.missingFrames }
        for (index, frame) in frames.enumerated() {
            guard frame.imagePath == (try frameFilename(frame, index: index)),
                  try isRegularFile(directory.appending(path: frame.imagePath)) else {
                throw StoreError.missingFrames
            }
        }
        return record
    }

    private static func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink == false
    }

    private static func frameFilename(_ frame: PoachKeyframe, index: Int) throws -> String {
        guard ["start", "peak", "settled"].contains(frame.kind), frame.timeMs >= 0 else {
            throw StoreError.missingFrames
        }
        return "preset-\(index)-\(frame.kind)-\(frame.timeMs)ms.png"
    }

    private static func snapshot(_ inspection: PoachInspection, frames: [PoachKeyframe],
                                 annotations: [InteractionAnnotation]) -> PoachInspection {
        PoachInspection(capture: inspection.capture, mediaType: inspection.mediaType, sourcePath: "", durationMs: inspection.durationMs,
                        keyframes: frames, palette: inspection.palette, timing: inspection.timing,
                        pointerTrace: inspection.pointerTrace, annotations: annotations,
                        browserEvidence: inspection.browserEvidence, visualFontMatch: inspection.visualFontMatch)
    }

    private static func compactPNG(_ imageSource: CGImageSource) throws -> Data {
        guard CGImageSourceGetType(imageSource) == UTType.png.identifier as CFString else {
            throw StoreError.missingFrames
        }
        // Preserve the largest lossless frame that fits the favorite’s storage budget.
        for size in frameSizes {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ]
            let data = NSMutableData()
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw StoreError.missingFrames
            }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw StoreError.missingFrames }
            guard data.length <= frameByteLimit else { continue }
            return data as Data
        }
        throw StoreError.missingFrames
    }

    private static func makeHandoffDirectory() throws -> URL {
        var template = files.temporaryDirectory.appending(path: "poach-XXXXXX").path.utf8CString
        let path = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress).map { String(cString: $0) }
        }
        guard let path else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
