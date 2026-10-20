import AppKit

/// One bounded base bitmap and one composite, shared across selection and pan redraws.
@MainActor
final class EditorPreviewCache {
    private var source: NSImage?
    private var canvas: CanvasConfiguration?
    private var annotations: [Annotation] = []
    private var limit = 0
    private var backgroundDate: Date?
    private var base: NSImage?
    private var composite: NSImage?
    private var includesBackground = true

    func render(_ request: RenderRequest, maxPixelDimension: Int) throws -> NSImage {
        let date = request.canvas.backgroundImageURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        if source !== request.image || canvas != request.canvas || limit != maxPixelDimension || date != backgroundDate || includesBackground != request.includeBackground {
            source = request.image; canvas = request.canvas; limit = maxPixelDimension; backgroundDate = date
            includesBackground = request.includeBackground
            base = nil; composite = nil
        }
        if base == nil {
            var baseCanvas = request.canvas
            baseCanvas.watermark = nil
            base = try ExportRenderer.render(RenderRequest(image: request.image, annotations: [],
                canvas: baseCanvas, includeBackground: includesBackground), maxPixelDimension: limit)
        }
        if composite == nil || annotations != request.annotations {
            composite = try ExportRenderer.render(request, maxPixelDimension: limit, baseImage: base)
            annotations = request.annotations
        }
        return composite!
    }
}
