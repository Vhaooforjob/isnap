import AppKit

enum CutAxis: String, CaseIterable, Identifiable { case horizontal, vertical; var id: String { rawValue }
    var title: String { self == .horizontal ? String(localized: "Horizontal strip") : String(localized: "Vertical strip") }
}
struct CutOutResult { let image: CGImage; let annotations: [Annotation]; let flattened: Bool }
actor CutOutService {
    func apply(image: CGImage, annotations: [Annotation], axis: CutAxis, start: Int, end: Int) throws -> CutOutResult {
        let limit = axis == .horizontal ? image.height : image.width
        guard start >= 0, end > start, end <= limit, end - start < limit else { throw ExportError.invalidImage }
        let low = CGFloat(start), high = CGFloat(end), removed = high - low
        let needsFlatten = annotations.contains { item in
            if item.type == .magnifier || item.type == .spotlight || item.rotation != 0 { return true }
            let r = item.normalizedFrame.insetBy(dx: -item.strokeWidth, dy: -item.strokeWidth)
            let a = axis == .horizontal ? r.minY : r.minX, b = axis == .horizontal ? r.maxY : r.maxX
            return !item.type.isPrivacyMask && a < high && b > low
        }
        let source: CGImage
        if needsFlatten {
            // Freeze the complete sanitized composition when a cut crosses a layer. Undo retains all originals.
            let rendered = try ExportRenderer.render(RenderRequest(image: NSImage(cgImage: image, size: .zero),
                annotations: annotations, canvas: .sourcePixels, includeBackground: false))
            guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
            source = cg
        } else { source = image }
        let output = try Self.cut(source, axis: axis, start: start, end: end)
        let shifted = needsFlatten ? [] : annotations.compactMap { item -> Annotation? in
            var result = item; let r = item.normalizedFrame
            func compress(_ x: CGFloat) -> CGFloat { x <= low ? x : x >= high ? x - removed : low }
            if axis == .horizontal {
                result.frame.origin.y = compress(r.minY); result.frame.size.height = compress(r.maxY) - compress(r.minY)
                if r.height > 0 && item.type.isPrivacyMask && result.frame.height <= 0 { return nil }
            } else {
                result.frame.origin.x = compress(r.minX); result.frame.size.width = compress(r.maxX) - compress(r.minX)
                if r.width > 0 && item.type.isPrivacyMask && result.frame.width <= 0 { return nil }
            }
            return result
        }
        try Task.checkCancellation()
        return CutOutResult(image: output, annotations: shifted, flattened: needsFlatten)
    }

    static func cut(_ image: CGImage, axis: CutAxis, start: Int, end: Int) throws -> CGImage {
        let limit = axis == .horizontal ? image.height : image.width
        guard start >= 0, start < end, end <= limit, end - start < limit else { throw ExportError.invalidImage }
        let width = image.width - (axis == .vertical ? end - start : 0)
        let height = image.height - (axis == .horizontal ? end - start : 0)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.invalidImage }
        let first = axis == .horizontal ? CGRect(x: 0, y: 0, width: image.width, height: start) : CGRect(x: 0, y: 0, width: start, height: image.height)
        let second = axis == .horizontal ? CGRect(x: 0, y: end, width: image.width, height: limit - end) : CGRect(x: end, y: 0, width: limit - end, height: image.height)
        if start > 0, let crop = image.cropping(to: first) {
            context.draw(crop, in: CGRect(x: 0, y: height - crop.height, width: crop.width, height: crop.height))
        }
        if end < limit, let crop = image.cropping(to: second) {
            context.draw(crop, in: CGRect(x: axis == .vertical ? start : 0, y: 0, width: crop.width, height: crop.height))
        }
        guard let output = context.makeImage() else { throw ExportError.invalidImage }; return output
    }
}
