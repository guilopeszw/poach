import AppKit
import Foundation

@main struct EvidenceStorageTests {
    @MainActor static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "poach-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let name = "Synthetic evidence test \(UUID().uuidString)"
        var owned: [UUID] = []
        defer { for id in owned { try? PoachFavoriteStore.delete(id: id) } }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 640, bitsPerPixel: 32)!
        memset(image.bitmapData!, 200, 640 * 90)
        let png = temporary.appending(path: "synthetic.png")
        try image.representation(using: .png, properties: [:])!.write(to: png)
        let element: [String: Any] = ["tag": "span", "role": "", "classes": "fixture"]
        let browser: [String: Any] = ["version": 1, "origin": "https://example.com", "target": element, "startedAtEpochMs": 100_000, "durationMs": 1_000, "events": [], "states": [["atMs": 0, "rect": [0, 0, 160, 90], "styles": ["fontSize": "12px"], "text": "Synthetic"]], "animations": [], "targetRemoved": false, "components": [["id": 0, "parent": -1, "target": element, "rect": [1, 2, 30, 20], "text": "Child", "styles": ["fontSize": "12px"]]]]
        let raw: [String: Any] = ["mediaType": "image", "sourcePath": png.path, "durationMs": 0, "keyframes": [["kind": "start", "timeMs": 0, "imagePath": png.path]], "palette": ["#C8C8C8"], "timing": ["durationMs": 0, "bezier": NSNull(), "token": "Still image"], "capture": ["widthPx": 160, "heightPx": 90, "deviceScale": 2, "widthPoints": 80, "heightPoints": 45, "imageMaxSize": 1280], "browserEvidence": browser]
        let result = try JSONDecoder().decode(PoachInspection.self, from: JSONSerialization.data(withJSONObject: raw))
        let id = try PoachFavoriteStore.save(name: name, result: result, context: "Synthetic", annotations: [])
        owned.append(id)
        let favorite = try PoachFavoriteStore.list().first { $0.id == id }!
        let portable = temporary.appending(path: "fixture.poach")
        try PoachFavoriteStore.export(favorite, to: portable)
        let before = Set(try PoachFavoriteStore.list().map(\.id))
        try PoachFavoriteStore.importHandoff(from: portable)
        let imported = try PoachFavoriteStore.list().first { !before.contains($0.id) && $0.name == name }!
        owned.append(imported.id)
        let restored = try PoachFavoriteStore.prepareHandoff(imported).result
        let linkedDirectory = URL(filePath: restored.keyframes[0].imagePath).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: linkedDirectory) }
        precondition(restored.capture?.widthPx == 160 && restored.capture?.deviceScale == 2 && restored.capture?.widthPoints == 80)
        precondition(restored.browserEvidence?.components?.first?.text == "Child")
        precondition(restored.sourcePath.isEmpty)
        try PoachFavoriteStore.delete(id: imported.id)
        owned.removeAll { $0 == imported.id }
        precondition(FileManager.default.fileExists(atPath: restored.keyframes[0].imagePath))
        // Exercise the actual app handoff writer and restore the user's latest snapshot.
        let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Poach")
        let latest = cache.appending(path: "active-brief.json")
        let prior = try? Data(contentsOf: latest)
        let briefID = try PoachHandoff.share(restored, context: "Synthetic test", annotations: [])
        defer {
            if let current = try? Data(contentsOf: latest), let object = try? JSONSerialization.jsonObject(with: current) as? [String: Any], object["briefId"] as? String == briefID {
                if let prior { try? prior.write(to: latest, options: .atomic) }
                else { try? FileManager.default.removeItem(at: latest) }
            }
            try? FileManager.default.removeItem(at: cache.appending(path: "briefs/\(briefID.lowercased()).json"))
        }
        let shared = try JSONSerialization.jsonObject(with: Data(contentsOf: latest)) as! [String: Any]
        let evidence = shared["evidence"] as! [String: Any]
        precondition((evidence["capture"] as? [String: Any])?["widthPx"] as? Int == 160)
        precondition(((evidence["browserEvidence"] as? [String: Any])?["components"] as? [[String: Any]])?.count == 1)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: portable)) as! [String: Any]
        var inspection = legacy["inspection"] as! [String: Any]
        inspection.removeValue(forKey: "capture")
        var oldBrowser = inspection["browserEvidence"] as! [String: Any]
        oldBrowser.removeValue(forKey: "components"); inspection["browserEvidence"] = oldBrowser
        legacy["inspection"] = inspection
        let oldFile = temporary.appending(path: "old.poach")
        try JSONSerialization.data(withJSONObject: legacy).write(to: oldFile)
        let oldBefore = Set(try PoachFavoriteStore.list().map(\.id))
        try PoachFavoriteStore.importHandoff(from: oldFile)
        let old = try PoachFavoriteStore.list().first { !oldBefore.contains($0.id) && $0.name == name }!
        owned.append(old.id)
        let oldResult = try PoachFavoriteStore.prepareHandoff(old).result
        defer { try? FileManager.default.removeItem(at: URL(filePath: oldResult.keyframes[0].imagePath).deletingLastPathComponent()) }
        precondition(oldResult.capture == nil && oldResult.browserEvidence?.components == nil)
        print("Evidence favorite/export/import/share and legacy compatibility passed")
    }
}
