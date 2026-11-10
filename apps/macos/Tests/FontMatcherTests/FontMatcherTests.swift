import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum FontMatcherTests {
    static func main() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "poach-font-tests-\(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        let sample = "Some interfaces are worth poaching."
        let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)
        for (face, darkBackground) in [("Georgia-BoldItalic", false), ("Menlo-Regular", true)] {
            let url = directory.appending(path: face + ".png")
            makeScreenshot([sample], face: face, darkBackground: darkBackground, at: url)
            precondition(PoachFontMatcher.containsReadableText(in: url), "Text gate hid \(face)")
            let result = try PoachFontMatcher.match(imageURL: url, selection: fullImage)
            precondition(result.text == sample, "Unexpected OCR result: \(result.text)")
            precondition(result.matches.first?.postScriptName == face, "Expected \(face), got \(result.matches)")
        }

        let blank = directory.appending(path: "blank.png")
        makeScreenshot([], face: "Georgia", darkBackground: false, at: blank)
        precondition(!PoachFontMatcher.containsReadableText(in: blank), "Blank image should hide Snatch font")
        do {
            _ = try PoachFontMatcher.match(imageURL: blank, selection: fullImage)
            preconditionFailure("Blank selection should fail")
        } catch PoachFontMatcher.Failure.noText {}

        let multiline = directory.appending(path: "multiline.png")
        makeScreenshot([sample, "Keep the type editable."], face: "Georgia", darkBackground: false, at: multiline)
        precondition(PoachFontMatcher.containsReadableText(in: multiline), "Users should be able to select a line")
        do {
            _ = try PoachFontMatcher.match(imageURL: multiline, selection: fullImage)
            preconditionFailure("Multiline selection should fail")
        } catch PoachFontMatcher.Failure.multipleLines {}

        let topLine = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = try PoachFontMatcher.match(imageURL: multiline, selection: topLine)
        precondition(cropped.text == sample, "Crop should select the top line")
        precondition(cropped.matches.first?.region == .init(x: 0, y: 0, width: 1, height: 0.5))
        let match = cropped.matches[0]
        let encoded = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(PoachFontMatch.self, from: encoded)
        let bottomLine = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let second = try PoachFontMatcher.match(imageURL: multiline, selection: bottomLine)
        let secondMatch = second.matches.first { $0.id == match.id }
        precondition(secondMatch != nil && secondMatch != match, "The same font can be selected from a new crop")
        precondition(decoded.region == match.region, "The selected region should survive handoff encoding")
        let legacy = Data(#"{"family":"Georgia","face":"Regular","postScriptName":"Georgia"}"#.utf8)
        let legacyMatch = try JSONDecoder().decode(PoachFontMatch.self, from: legacy)
        precondition(legacyMatch.region == nil, "Older font matches should still decode")
        print("Font matcher verified dark and light text, text gating, and single-line selection.")
    }

    private static func makeScreenshot(_ lines: [String], face: String, darkBackground: Bool, at url: URL) {
        let width = 1_100
        let height = max(1, lines.count) * 100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: darkBackground ? 0.1 : 0.95, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName(face as CFString, 48, nil)
        let ink = CGColor(gray: darkBackground ? 0.95 : 0.1, alpha: 1)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
            ]))
            context.textPosition = CGPoint(x: 24, y: height - index * 100 - 65)
            CTLineDraw(line, context)
        }

        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
