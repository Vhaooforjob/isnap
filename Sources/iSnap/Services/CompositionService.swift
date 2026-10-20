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

    func pdf(_ pages: [CompositionPage], captions: Bool) throws -> Data {
        guard !pages.isEmpty else { throw ExportError.invalidImage }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ExportError.encodingFailed }
        for page in pages {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = ImageIOService.thumbnail(at: page.url, maxPixelSize: 4096) else { throw ExportError.invalidImage }
                let height = CGFloat(image.height) + (captions ? 48 : 0)
                var box = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.draw(image, in: CGRect(x: 0, y: captions ? 48 : 0, width: image.width, height: image.height))
                if captions { drawCaption(page.caption, in: context, rect: CGRect(x: 12, y: 0, width: CGFloat(image.width) - 24, height: 48)) }
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    private func drawCaption(_ text: String, in context: CGContext, rect: CGRect) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]))
        context.saveGState(); context.clip(to: rect)
        context.textPosition = CGPoint(x: rect.minX + 4, y: rect.midY - 7)
        CTLineDraw(line, context); context.restoreGState()
    }
}
