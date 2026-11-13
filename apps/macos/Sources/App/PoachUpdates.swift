import AppKit
import Foundation

enum PoachUpdates {
    static let endpoint = URL(string: "https://api.github.com/repos/guilopeszw/poach/releases/latest")!

    struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        func download(after installedVersion: String) throws -> URL? {
            guard !draft, !prerelease,
                  let latest = Version(String(tagName.dropFirst())), tagName.hasPrefix("v"),
                  let installed = Version(installedVersion) else {
                throw CheckError.invalidRelease
            }
            guard latest > installed else { return nil }

            let filename = "Poach-arm64.zip"
            let expected = "https://github.com/guilopeszw/poach/releases/download/\(tagName)/\(filename)"
            guard let asset = assets.first(where: {
                $0.name == filename && $0.browserDownloadUrl.absoluteString == expected
            }) else {
                throw CheckError.missingDownload
            }
            return asset.browserDownloadUrl
        }
    }

    private struct Version: Comparable {
        let components: [Int]

        init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard parts.count == 3, numbers.count == 3,
                  numbers.map(String.init).joined(separator: ".") == value,
                  numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            components = numbers
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }

    enum CheckError: Error {
        case invalidRelease, missingDownload, requestFailed
    }

    static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CheckError.requestFailed }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw CheckError.requestFailed }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    @MainActor
    static func check() async {
        do {
            guard let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
                throw CheckError.invalidRelease
            }
            guard let release = try await latestRelease() else {
                show("No public release available", detail: "Check again after Poach publishes a release.")
                return
            }
            guard let download = try release.download(after: installed) else {
                show("Poach is up to date", detail: "You’re running Poach \(installed).")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Poach \(release.tagName.dropFirst()) is available"
            alert.informativeText = "Download the ZIP, quit Poach, and replace Poach.app in Applications."
            alert.addButton(withTitle: "Download Update")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn, !NSWorkspace.shared.open(download) {
                show("Couldn’t open the download", detail: "Check your default browser and try again.")
            }
        } catch CheckError.missingDownload {
            show("Update download unavailable", detail: "The latest release is missing the Apple silicon download.")
        } catch {
            show("Couldn’t check for updates", detail: "Try again in a moment.")
        }
    }

    @MainActor
    private static func show(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
