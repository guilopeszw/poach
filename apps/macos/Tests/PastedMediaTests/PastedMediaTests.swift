import AppKit
import Foundation

@MainActor
func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
func withPasteboard(_ body: (NSPasteboard) -> Void) {
    let board = NSPasteboard(name: NSPasteboard.Name("poach-paste-test-\(UUID().uuidString)"))
    board.clearContents()
    body(board)
    board.releaseGlobally()
}

@MainActor
func sampleImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 4, height: 3))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 3).fill()
    image.unlockFocus()
    return image
}

@MainActor
func expectSavedPNG(_ result: Result<URL, PoachPastedMedia.Failure>, _ label: String) {
    guard case .success(let url) = result else { check(false, "\(label): expected a saved image"); return }
    defer { try? FileManager.default.removeItem(at: url) }
    check(url.lastPathComponent.range(of: #"^screenshot-[0-9A-F-]{36}\.png$"#, options: .regularExpression) != nil,
          "\(label): file name \(url.lastPathComponent)")
    check(url.deletingLastPathComponent().lastPathComponent == "Poach", "\(label): saved outside the Poach folder")
    let data = (try? Data(contentsOf: url)) ?? Data()
    check(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(label): not PNG data")
    let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    check(mode == 0o600, "\(label): permissions \(String(mode, radix: 8))")
}

@MainActor
func run() {
    let tiff = sampleImage().tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!

    withPasteboard { board in
        board.setData(png, forType: .png)
        expectSavedPNG(PoachPastedMedia.read(from: board), "PNG data")
    }
    withPasteboard { board in
        board.setData(tiff, forType: .tiff)
        expectSavedPNG(PoachPastedMedia.read(from: board), "TIFF data")
    }

    let folder = FileManager.default.temporaryDirectory.appending(path: "poach-paste-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let photo = folder.appending(path: "photo.jpeg")
    let notes = folder.appending(path: "notes.txt")
    try! png.write(to: photo)
    try! Data("hi".utf8).write(to: notes)

    withPasteboard { board in
        board.writeObjects([photo as NSURL])
        guard case .success(let url) = PoachPastedMedia.read(from: board) else { return check(false, "copied file") }
        check(url.standardizedFileURL == photo.standardizedFileURL, "copied file: opened \(url.path)")
    }
    withPasteboard { board in
        board.writeObjects([photo as NSURL, photo as NSURL])
        guard case .failure(let failure) = PoachPastedMedia.read(from: board) else { return check(false, "two files") }
        check(failure.message == "Paste one file at a time.", "two files: \(failure.message)")
    }
    withPasteboard { board in
        board.writeObjects([notes as NSURL])
        guard case .failure(let failure) = PoachPastedMedia.read(from: board) else { return check(false, "text file") }
        check(failure.message == "Use PNG, JPEG, WebP, TIFF, BMP, MP4, or MOV.", "text file: \(failure.message)")
    }
    withPasteboard { board in
        board.setString("just text", forType: .string)
        guard case .failure(let failure) = PoachPastedMedia.read(from: board) else { return check(false, "plain text") }
        check(failure.message == "Copy an image or video first, then paste.", "plain text: \(failure.message)")
    }
    print("Pasted media passed.")
}

@main enum PastedMediaTests {
    @MainActor static func main() { run() }
}
