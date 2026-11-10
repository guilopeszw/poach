import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

struct PoachFontMatch: Codable, Equatable, Identifiable, Sendable {
    struct Region: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let family: String
    let face: String
    let postScriptName: String
    let region: Region?

    var id: String { postScriptName }
}

enum PoachFontMatcher {
    // Calibrated with normal, small, low-contrast, and visibly distorted UI text.
    private static let maximumMatchDistance = 0.22

    struct TextLine: Equatable, Sendable {
        let text: String
        let bounds: CGRect
    }

    struct Result: Sendable {
        let original: CGImage
        let text: String
        let matches: [PoachFontMatch]
    }

    enum Failure: LocalizedError {
        case noText
        case multipleLines
        case noMatch

        var errorDescription: String? {
            switch self {
            case .noText: "Select a clear line of text with a little space around it."
            case .multipleLines: "Select one line of text at a time."
            case .noMatch: "No close match among installed fonts. Try a larger, clearer line of text."
            }
        }
    }

    static func detectTextLines(in imageURL: URL) -> [TextLine] {
        guard let image = loadImage(at: imageURL, maxSide: 3_072),
              let observations = try? recognizeText(in: image) else { return [] }
        let imageBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        return observations.compactMap { observation -> TextLine? in
            guard let text = recognizedText(in: observation), text.count >= 2,
                  text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
            let box = observation.boundingBox
            let bounds = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            let padded = bounds.insetBy(dx: -2 / CGFloat(image.width), dy: -2 / CGFloat(image.height))
                .intersection(imageBounds)
            guard !padded.isEmpty else { return nil }
            return TextLine(text: text, bounds: padded)
        }
        .sorted { $0.bounds.midY < $1.bounds.midY }
    }

    // The selection uses normalized, top-left coordinates in the displayed image.
    static func match(imageURL: URL, selection: CGRect, detectedText: String? = nil,
                      installedFontNames: [String]? = nil) throws -> Result {
        guard let image = loadImage(at: imageURL, maxSide: 4_096) else { throw Failure.noText }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: selection.minX * bounds.width, y: selection.minY * bounds.height,
                          width: selection.width * bounds.width, height: selection.height * bounds.height)
            .integral.intersection(bounds)
        guard rect.width >= 8, rect.height >= 8, let crop = image.cropping(to: rect) else {
            throw Failure.noText
        }

        let text: String
        if let detectedText {
            text = detectedText
        } else {
            let lines = try recognizeText(in: crop).compactMap(recognizedText(in:))
            guard !lines.isEmpty else { throw Failure.noText }
            guard lines.count == 1 else { throw Failure.multipleLines }
            text = lines[0]
        }
        guard (2...96).contains(text.count), let reference = Mask(image: crop) else { throw Failure.noText }

        // Use the actual crop after clipping and rounding to image pixels.
        let region = PoachFontMatch.Region(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                                           width: rect.width / bounds.width, height: rect.height / bounds.height)
        let names = installedFontNames ?? (CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        var bestByFamily: [String: (match: PoachFontMatch, error: Double)] = [:]
        for name in names where !name.hasPrefix(".") {
            try Task.checkCancellation()
            let font = CTFontCreateWithName(name as CFString, 40, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            ))
            // Core Text substitutes fonts for unsupported glyphs. Compare only actual candidates.
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty,
                  runs.allSatisfy({ run in
                      let attributes = CTRunGetAttributes(run) as NSDictionary
                      guard let runFont = attributes[kCTFontAttributeName],
                            CFGetTypeID(runFont as CFTypeRef) == CTFontGetTypeID() else { return false }
                      let actual = unsafeBitCast(runFont as CFTypeRef, to: CTFont.self)
                      return CTFontCopyPostScriptName(actual) as String == name
                  }),
                  let rendered = render(line), let candidate = Mask(image: rendered) else { continue }
            let error = reference.distance(to: candidate)
            guard error <= maximumMatchDistance else { continue }
            let family = CTFontCopyFamilyName(font) as String
            if error < (bestByFamily[family]?.error ?? .infinity) {
                let face = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? name
                let match = PoachFontMatch(family: family, face: face, postScriptName: name, region: region)
                bestByFamily[family] = (match, error)
            }
        }
        let matches = bestByFamily.values
            .sorted { ($0.error, $0.match.postScriptName) < ($1.error, $1.match.postScriptName) }
            .prefix(3).map(\.match)
        guard !matches.isEmpty else { throw Failure.noMatch }
        return Result(original: crop, text: text, matches: matches)
    }

    private static func loadImage(at url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func recognizedText(in observation: VNRecognizedTextObservation) -> String? {
        observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recognizeText(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }

    private static func render(_ line: CTLine) -> CGImage? {
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).integral
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0,
              bounds.width <= 6_000, bounds.height <= 200,
              let context = CGContext(data: nil, width: Int(bounds.width) + 4, height: Int(bounds.height) + 4,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.textPosition = CGPoint(x: 2 - bounds.minX, y: 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private struct Mask {
        static let width = 128
        static let height = 28
        let aspect: Double
        let pixels: [UInt8]

        init?(image: CGImage) {
            let scale = min(1, 768.0 / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale))
            let height = max(1, Int(Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.fill(rect)
            context.draw(image, in: rect)

            // A single-line selection has background along most of its border.
            let edge = ((0..<width).map { Int(data[$0]) } +
                (0..<width).map { Int(data[(height - 1) * width + $0]) } +
                (0..<height).flatMap { [Int(data[$0 * width]), Int(data[$0 * width + width - 1])] }).sorted()
            let background = edge[edge.count / 2]
            let minGray = (0..<(width * height)).map { Int(data[$0]) }.min() ?? background
            let maxGray = (0..<(width * height)).map { Int(data[$0]) }.max() ?? background
            let darkInk = background - minGray >= maxGray - background
            let contrast = darkInk ? background - minGray : maxGray - background
            guard contrast >= 24 else { return nil }

            var left = width, right = -1, top = height, bottom = -1
            for y in 0..<height {
                for x in 0..<width where abs(Int(data[y * width + x]) - background) >= contrast / 2 {
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
            guard left < right, top < bottom else { return nil }
            aspect = Double(right - left + 1) / Double(bottom - top + 1)
            pixels = (0..<Self.height).flatMap { row in
                (0..<Self.width).map { column in
                    let y = top + row * (bottom - top) / (Self.height - 1)
                    let x = left + column * (right - left) / (Self.width - 1)
                    let gray = Int(data[y * width + x])
                    let ink = darkInk ? background - gray : gray - background
                    return UInt8(clamping: ink * 255 / contrast)
                }
            }
        }

        func distance(to other: Mask) -> Double {
            let pixelError = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            return Double(pixelError) / Double(pixels.count * 255) + abs(log(aspect / other.aspect)) * 0.2
        }
    }
}
