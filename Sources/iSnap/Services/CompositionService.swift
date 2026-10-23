import AppKit
import CoreText

struct CompositionPage: Identifiable {
    var id = UUID()
    var url: URL
    var caption: String
}

struct CompositionOptions {
    var horizontal = false
    var spacing: CGFloat = 24
    var crossDimension: CGFloat = 1600
    var captions = true
}

actor CompositionService {
    func combine(_ pages: [CompositionPage], options: CompositionOptions) throws -> CGImage {
        guard !pages.isEmpty else { throw ExportError.invalidImage }
        let sizes = try pages.map { page -> CGSize in
            guard let size = ImageIOService.pixelSize(at: page.url), size.width > 0, size.height > 0 else { throw ExportError.invalidImage }
            let scale = min(1, options.crossDimension / (options.horizontal ? size.height : size.width))
            return CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        }
        let gap = options.spacing.clamped(to: 0...200), caption: CGFloat = options.captions ? 48 : 0
        let width = options.horizontal
            ? sizes.reduce(gap) { $0 + $1.width + gap }
            : (sizes.map(\.width).max() ?? 0) + gap * 2
        let height = options.horizontal
            ? (sizes.map(\.height).max() ?? 0) + caption + gap * 2
            : sizes.reduce(gap) { $0 + $1.height + caption + gap }
        guard width * height <= 80_000_000, width <= 60_000, height <= 60_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.tooLarge }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var cursor = gap
        for (page, size) in zip(pages, sizes) {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = ImageIOService.thumbnail(at: page.url, maxPixelSize: Int(max(size.width, size.height))) else { throw ExportError.invalidImage }
                let x = options.horizontal ? cursor : (width - size.width) / 2
                let y = options.horizontal ? height - gap - size.height : height - cursor - size.height
                context.draw(image, in: CGRect(x: x, y: y, width: size.width, height: size.height))
                if options.captions { drawCaption(page.caption, in: context, rect: CGRect(x: x, y: y - caption, width: size.width, height: caption)) }
                cursor += (options.horizontal ? size.width : size.height + caption) + gap
            }
        }
        guard let result = context.makeImage() else { throw ExportError.invalidImage }
        return result
    }

    func pdf(_ pages: [CompositionPage], captions: Bool, searchable: Bool = false,
             layout: PDFPageLayout = .original, progress: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        guard !pages.isEmpty else { throw ExportError.invalidImage }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ExportError.encodingFailed }
        let parser = ScreenshotParserService()
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let image = try ImageIOService.fullImage(at: page.url)
            let regions: [RecognizedRegion]
            if searchable {
                regions = try await parser.parse(image, recognizeCodes: false, progress: { tile, count in
                    progress?(String(localized: "Image \(index + 1)/\(pages.count): OCR \(tile)/\(count)"))
                }).regions
            } else { regions = [] }
            let size = CGSize(width: image.width, height: image.height)
            let slices = Self.pageSlices(size: size, layout: layout, captions: captions, regions: regions)
            for (number, slice) in slices.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let crop = image.cropping(to: slice) else { throw ExportError.invalidImage }
                    let caption: CGFloat = captions ? 48 : 0
                    let pageSize = layout.size ?? CGSize(width: slice.width, height: slice.height + caption)
                    let margin: CGFloat = layout == .original ? 0 : 24
                    let scale = min((pageSize.width - margin * 2) / slice.width, (pageSize.height - margin * 2 - caption) / slice.height)
                    let rect = CGRect(x: margin, y: pageSize.height - margin - slice.height * scale,
                        width: slice.width * scale, height: slice.height * scale)
                    var box = CGRect(origin: .zero, size: pageSize)
                    let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                    context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                    context.draw(crop, in: rect)
                    if captions { drawCaption(page.caption, in: context, rect: CGRect(x: margin + 4, y: margin, width: pageSize.width - margin * 2 - 8, height: caption)) }
                    let local = regions.filter { slice.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }.map {
                        RecognizedRegion(text: $0.text, rect: $0.rect.offsetBy(dx: -slice.minX, dy: -slice.minY))
                    }
                    context.saveGState()
                    context.translateBy(x: rect.minX, y: rect.minY)
                    context.scaleBy(x: scale, y: scale)
                    Self.drawSearchableText(local, imageHeight: slice.height, offset: 0, in: context)
                    context.restoreGState()
                    context.endPDFPage()
                }
                progress?(String(localized: "Image \(index + 1)/\(pages.count): page \(number + 1)/\(slices.count)"))
            }
        }
        context.closePDF()
        try Task.checkCancellation()
        return data as Data
    }

    static func pageSlices(size: CGSize, layout: PDFPageLayout, captions: Bool, regions: [RecognizedRegion] = []) -> [CGRect] {
        guard size.width > 0, size.height > 0 else { return [] }
        guard let paper = layout.size else { return [CGRect(origin: .zero, size: size)] }
        let scale = (paper.width - 48) / size.width
        let height = max(1, floor((paper.height - 48 - (captions ? 48 : 0)) / scale))
        var slices: [CGRect] = [], y: CGFloat = 0
        while y < size.height {
            var end = min(size.height, y + height)
            // Prefer a break before a text line instead of splitting its glyphs.
            if end < size.height, let crossing = regions.filter({ $0.rect.minY < end && $0.rect.maxY > end && $0.rect.minY > y + height * 0.8 }).map(\.rect.minY).min() {
                end = max(y + 1, floor(crossing) - 2)
            }
            slices.append(CGRect(x: 0, y: y, width: size.width, height: end - y)); y = end
        }
        return slices
    }

    static func drawSearchableText(_ regions: [RecognizedRegion], imageHeight: CGFloat, offset: CGFloat, in context: CGContext) {
        for region in regions where !region.text.isEmpty && region.rect.width > 0 && region.rect.height > 0 {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: region.text,
                attributes: [.font: NSFont.systemFont(ofSize: region.rect.height)]))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            guard width > 0, ascent + descent > 0 else { continue }
            context.saveGState()
            context.translateBy(x: region.rect.minX, y: imageHeight - region.rect.maxY + offset)
            context.scaleBy(x: region.rect.width / width, y: region.rect.height / (ascent + descent))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 0, y: descent)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private func drawCaption(_ text: String, in context: CGContext, rect: CGRect) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]))
        context.saveGState(); context.clip(to: rect)
        context.textPosition = CGPoint(x: rect.minX + 4, y: rect.midY - 7)
        CTLineDraw(line, context); context.restoreGState()
    }
}

enum PDFPageLayout: String, CaseIterable, Identifiable {
    case original, a4, letter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: String(localized: "Original Image Size")
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }
    var size: CGSize? {
        switch self {
        case .original: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}
