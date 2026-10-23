import CoreGraphics
import Foundation
import Vision

struct ScreenshotParseResult: Equatable, Sendable {
    let text: String
    let lineCount: Int
    var regions: [RecognizedRegion] = []
    var codes: [RecognizedCode] = []
}

struct RecognizedGlyph: Equatable, Sendable {
    let range: NSRange
    let rect: CGRect
}

struct RecognizedCode: Identifiable, Equatable, Sendable {
    let id = UUID()
    let payload: String
    let rect: CGRect
    var webURL: URL? {
        guard let url = URL(string: payload), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}

struct RecognizedRegion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    /// Top-left source pixel coordinates, including tile offsets.
    let rect: CGRect
    var glyphs: [RecognizedGlyph]? = nil

    var mayContainPrivateInformation: Bool {
        let range = NSRange(text.startIndex..., in: text)
        let email = try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
        let phone = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
        return email?.firstMatch(in: text, range: range) != nil || phone?.firstMatch(in: text, range: range) != nil
    }

    func boundingRect(for range: NSRange) -> CGRect {
        guard let glyphs, !glyphs.isEmpty else { return rect }
        let matches = glyphs.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard !matches.isEmpty else { return rect }
        if let stringRange = Range(range, in: text) {
            for index in text[stringRange].indices where !text[index].isWhitespace {
                let characterRange = NSRange(index..<text.index(after: index), in: text)
                if !matches.contains(where: { NSIntersectionRange($0.range, characterRange).length == characterRange.length }) { return rect }
            }
        } else { return rect }
        return matches.reduce(CGRect.null) { $0.union($1.rect) }
    }
}

actor ScreenshotParserService {
    static func tiles(size: CGSize, edge: Int = 2048, overlap: Int = 192) -> [CGRect] {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, edge > overlap, overlap >= 0 else { return [] }
        func starts(_ dimension: Int) -> [Int] {
            if dimension <= edge { return [0] }
            var values = Array(stride(from: 0, to: dimension - edge, by: edge - overlap))
            if values.last != dimension - edge { values.append(dimension - edge) }
            return values
        }
        return starts(height).flatMap { y in starts(width).map { x in
            CGRect(x: x, y: y, width: min(edge, width - x), height: min(edge, height - y))
        } }
    }

    func parse(_ image: CGImage, includeGlyphs: Bool = false, recognizeCodes: Bool = true,
               progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ScreenshotParseResult {
        let tiles = Self.tiles(size: CGSize(width: image.width, height: image.height))
        var regions: [RecognizedRegion] = [], codes: [RecognizedCode] = []
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            guard let crop = image.cropping(to: tile) else { throw ExportError.invalidImage }
            let result = try autoreleasepool { try parseTile(crop, includeGlyphs: includeGlyphs, recognizeCodes: recognizeCodes) }
            for region in result.regions {
                let translated = RecognizedRegion(text: region.text, rect: region.rect.offsetBy(dx: tile.minX, dy: tile.minY),
                    glyphs: region.glyphs?.map { RecognizedGlyph(range: $0.range, rect: $0.rect.offsetBy(dx: tile.minX, dy: tile.minY)) })
                if let existing = regions.firstIndex(where: { Self.sameLine($0, translated) }) {
                    // Keep the more complete observation when overlapping tiles clip a line.
                    if translated.text.count > regions[existing].text.count { regions[existing] = translated }
                } else { regions.append(translated) }
            }
            for code in result.codes {
                let translated = RecognizedCode(payload: code.payload, rect: code.rect.offsetBy(dx: tile.minX, dy: tile.minY))
                if !codes.contains(where: { $0.payload == translated.payload && $0.rect.intersects(translated.rect) }) { codes.append(translated) }
            }
            progress?(index + 1, tiles.count)
        }
        regions.sort { a, b in abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5 ? a.rect.minX < b.rect.minX : a.rect.midY < b.rect.midY }
        return ScreenshotParseResult(text: OCRLayout.plain(regions, preserveLayout: false), lineCount: OCRLayout.rows(regions).count, regions: regions, codes: codes)
    }

    static func sameLine(_ a: RecognizedRegion, _ b: RecognizedRegion) -> Bool {
        let intersection = a.rect.intersection(b.rect)
        guard !intersection.isNull, abs(a.rect.midY - b.rect.midY) < max(a.rect.height, b.rect.height) * 0.5 else { return false }
        let smaller = min(a.rect.width * a.rect.height, b.rect.width * b.rect.height)
        return smaller > 0 && intersection.width * intersection.height / smaller > 0.5 &&
            (a.text.localizedStandardContains(b.text) || b.text.localizedStandardContains(a.text))
    }

    private func parseTile(_ image: CGImage, includeGlyphs: Bool, recognizeCodes: Bool) throws -> ScreenshotParseResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.002
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = ["vi-VT", "vi-VN", "en-US"].filter(supported.contains)
        if !languages.isEmpty { request.recognitionLanguages = languages }
        let barcode = VNDetectBarcodesRequest()
        barcode.symbologies = [.qr]
        let requests: [VNRequest] = recognizeCodes ? [request, barcode] : [request]
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform(requests)
        try Task.checkCancellation()
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
        }
        let regions: [RecognizedRegion] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let text = candidate.string
            var glyphs: [RecognizedGlyph]?
            if includeGlyphs {
                glyphs = text.indices.prefix(4096).compactMap { index in
                    let range = index..<text.index(after: index)
                    guard let box = try? candidate.boundingBox(for: range) else { return nil }
                    return RecognizedGlyph(range: NSRange(range, in: text), rect: pixels(box.boundingBox))
                }
            }
            return RecognizedRegion(text: text, rect: pixels(observation.boundingBox), glyphs: glyphs)
        }
        let codes = (barcode.results ?? []).compactMap { observation -> RecognizedCode? in
            guard let payload = observation.payloadStringValue else { return nil }
            return RecognizedCode(payload: payload, rect: pixels(observation.boundingBox))
        }
        return ScreenshotParseResult(text: regions.map(\.text).joined(separator: "\n"), lineCount: regions.count, regions: regions, codes: codes)
    }
}
