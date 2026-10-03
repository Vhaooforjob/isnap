import AppKit
import CoreText
import Foundation

struct RenderRequest {
    let image: NSImage
    let annotations: [Annotation]
    let canvas: CanvasConfiguration
    let includeBackground: Bool
}

enum ExportError: LocalizedError {
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The current image cannot be rendered."
        case .encodingFailed: "The rendered image could not be encoded."
        }
    }
}

enum ExportRenderer {
    static func render(_ request: RenderRequest) throws -> NSImage {
        guard let source = request.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.invalidImage
        }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let effectivePadding = request.includeBackground && request.canvas.showBackground ? request.canvas.padding : 0
        var outputSize = CGSize(
            width: sourceSize.width + effectivePadding * 2,
            height: sourceSize.height + effectivePadding * 2
        )
        if let ratio = request.canvas.outputRatio.value {
            if outputSize.width / outputSize.height > ratio {
                outputSize.height = outputSize.width / ratio
            } else {
                outputSize.width = outputSize.height * ratio
            }
        }
        outputSize.width = ceil(outputSize.width)
        outputSize.height = ceil(outputSize.height)

        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.invalidImage }

        if request.includeBackground && request.canvas.showBackground {
            if let url = request.canvas.backgroundImageURL,
               let background = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let sourceRatio = CGFloat(background.width) / CGFloat(background.height)
                let targetRatio = outputSize.width / outputSize.height
                let drawRect: CGRect
                if sourceRatio > targetRatio {
                    let width = outputSize.height * sourceRatio
                    drawRect = CGRect(x: (outputSize.width - width) / 2, y: 0, width: width, height: outputSize.height)
                } else {
                    let height = outputSize.width / sourceRatio
                    drawRect = CGRect(x: 0, y: (outputSize.height - height) / 2, width: outputSize.width, height: height)
                }
                context.draw(background, in: drawRect)
            } else {
                let colors = [request.canvas.gradient.start.nsColor.cgColor, request.canvas.gradient.end.nsColor.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: outputSize.height),
                        end: CGPoint(x: outputSize.width, y: 0),
                        options: []
                    )
                }
            }
        } else {
            context.clear(CGRect(origin: .zero, size: outputSize))
        }

        let available = CGRect(
            x: effectivePadding,
            y: effectivePadding,
            width: outputSize.width - effectivePadding * 2,
            height: outputSize.height - effectivePadding * 2
        )
        let insetScale = max(0.1, 1 - request.canvas.insetPercent / 100)
        let fitScale = min(available.width / sourceSize.width, available.height / sourceSize.height) * insetScale
        let imageSize = CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
        let imageRect = CGRect(
            x: (outputSize.width - imageSize.width) / 2,
            y: (outputSize.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )

        context.saveGState()
        if request.canvas.shadowSize > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -request.canvas.shadowSize * 0.25),
                blur: request.canvas.shadowSize,
                color: NSColor.black.withAlphaComponent(0.35).cgColor
            )
        }
        let clipPath = CGPath(roundedRect: imageRect, cornerWidth: request.canvas.cornerRadius, cornerHeight: request.canvas.cornerRadius, transform: nil)
        context.addPath(clipPath)
        context.clip()
        context.draw(source, in: imageRect)
        context.restoreGState()

        if request.canvas.borderEnabled {
            let alpha = request.canvas.borderOpacity.clamped(to: 0...1)
            context.setStrokeColor(request.canvas.borderColor.nsColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(request.canvas.borderWeight)
            let adjustment: CGFloat = switch request.canvas.borderPosition {
            case .outside: -request.canvas.borderWeight / 2
            case .center: 0
            case .inside: request.canvas.borderWeight / 2
            }
            let borderRect = imageRect.insetBy(dx: adjustment, dy: adjustment)
            context.addPath(CGPath(roundedRect: borderRect, cornerWidth: request.canvas.cornerRadius, cornerHeight: request.canvas.cornerRadius, transform: nil))
            context.strokePath()
        }

        AnnotationRenderer.draw(
            request.annotations,
            in: context,
            sourceSize: sourceSize,
            destination: imageRect
        )
        WatermarkRenderer.draw(request.canvas.watermark, in: context, bounds: CGRect(origin: .zero, size: outputSize))
        guard let result = context.makeImage() else { throw ExportError.invalidImage }
        return NSImage(cgImage: result, size: outputSize)
    }
}

private enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], in context: CGContext, sourceSize: CGSize, destination: CGRect) {
        let scaleX = destination.width / sourceSize.width
        let scaleY = destination.height / sourceSize.height
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: destination.minX + point.x * scaleX, y: destination.maxY - point.y * scaleY)
        }
        func map(_ rect: CGRect) -> CGRect {
            let normalized = CGRect(
                x: min(rect.minX, rect.maxX), y: min(rect.minY, rect.maxY),
                width: abs(rect.width), height: abs(rect.height)
            )
            return CGRect(
                x: destination.minX + normalized.minX * scaleX,
                y: destination.maxY - normalized.maxY * scaleY,
                width: normalized.width * scaleX,
                height: normalized.height * scaleY
            )
        }

        let spotlights = annotations.filter { $0.type == .spotlight }
        if !spotlights.isEmpty {
            let path = CGMutablePath()
            path.addRect(destination)
            for item in spotlights { path.addEllipse(in: map(item.normalizedFrame)) }
            context.saveGState()
            context.addPath(path)
            context.setFillColor(NSColor.black.withAlphaComponent(spotlights.first?.dimOpacity ?? 0.7).cgColor)
            context.drawPath(using: .eoFill)
            context.restoreGState()
        }

        for annotation in annotations where annotation.type != .spotlight {
            context.saveGState()
            let frame = map(annotation.normalizedFrame)
            if annotation.rotation != 0 {
                context.translateBy(x: frame.midX, y: frame.midY)
                context.rotate(by: -annotation.rotation * .pi / 180)
                context.translateBy(x: -frame.midX, y: -frame.midY)
            }
            context.setStrokeColor(annotation.stroke.nsColor.cgColor)
            context.setFillColor(annotation.fill.nsColor.cgColor)
            context.setLineWidth(max(1, annotation.strokeWidth * (scaleX + scaleY) / 2))
            context.setLineCap(.round)
            context.setLineJoin(.round)

            switch annotation.type {
            case .rectangle:
                context.addPath(CGPath(roundedRect: frame, cornerWidth: annotation.cornerRadius * scaleX, cornerHeight: annotation.cornerRadius * scaleY, transform: nil))
                paintPath(annotation, context)
            case .ellipse:
                context.addEllipse(in: frame)
                paintPath(annotation, context)
            case .line, .arrow:
                let rawStart = annotation.lineStartPoint
                let rawEnd = annotation.lineEndPoint
                let start = map(rawStart)
                let end = map(rawEnd)
                context.move(to: start)
                if annotation.type == .arrow && annotation.curved {
                    let control = map(CGPoint(
                        x: (rawStart.x + rawEnd.x) / 2 + annotation.curveOffset.x,
                        y: (rawStart.y + rawEnd.y) / 2 + annotation.curveOffset.y
                    ))
                    context.addQuadCurve(to: end, control: control)
                } else {
                    context.addLine(to: end)
                }
                context.strokePath()
                if annotation.type == .arrow { drawArrowHead(from: start, to: end, annotation: annotation, in: context) }
            case .text:
                drawText(annotation, frame: frame, context: context, scale: min(scaleX, scaleY))
            case .number:
                context.setFillColor(annotation.stroke.nsColor.cgColor)
                context.fillEllipse(in: frame)
                let markerLabel = annotation.markerLabel
                let markerScale = min(0.58, 0.9 / CGFloat(max(1, markerLabel.count)))
                let label = Annotation(
                    type: .text,
                    frame: annotation.frame,
                    stroke: .white,
                    text: markerLabel,
                    fontSize: min(annotation.frame.width, annotation.frame.height) * markerScale,
                    fontStyle: .bold,
                    textAlignment: .center
                )
                drawText(label, frame: frame, context: context, scale: min(scaleX, scaleY))
            case .image:
                if let data = annotation.imageData,
                   let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.setAlpha(annotation.effectiveImageOpacity)
                    context.interpolationQuality = .high
                    context.draw(image, in: frame)
                }
            case .select, .crop, .spotlight:
                break
            }
            context.restoreGState()
        }
    }

    private static func paintPath(_ annotation: Annotation, _ context: CGContext) {
        let hasFill = annotation.fill.alpha > 0
        let hasStroke = annotation.stroke.alpha > 0 && annotation.strokeWidth > 0
        if hasFill && hasStroke { context.drawPath(using: .fillStroke) }
        else if hasFill { context.fillPath() }
        else if hasStroke { context.strokePath() }
    }

    private static func drawArrowHead(from start: CGPoint, to end: CGPoint, annotation: Annotation, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(12, annotation.strokeWidth * 4)
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
        context.move(to: end)
        context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
        context.strokePath()
    }

    private static func drawText(_ annotation: Annotation, frame: CGRect, context: CGContext, scale: CGFloat) {
        let font: NSFont = switch annotation.fontStyle {
        case .regular: .systemFont(ofSize: annotation.fontSize * scale)
        case .bold: .boldSystemFont(ofSize: annotation.fontSize * scale)
        case .italic: NSFontManager.shared.convert(.systemFont(ofSize: annotation.fontSize * scale), toHaveTrait: .italicFontMask)
        case .boldItalic: NSFontManager.shared.convert(.boldSystemFont(ofSize: annotation.fontSize * scale), toHaveTrait: .italicFontMask)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch annotation.textAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let attributed = NSAttributedString(
            string: annotation.text,
            attributes: [.font: font, .foregroundColor: annotation.stroke.nsColor, .paragraphStyle: paragraph]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let x: CGFloat = switch annotation.textAlignment {
        case .left: frame.minX - bounds.minX
        case .center: frame.midX - bounds.width / 2 - bounds.minX
        case .right: frame.maxX - bounds.width - bounds.minX
        }
        let y = frame.midY - bounds.height / 2 - bounds.minY
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}

private enum WatermarkRenderer {
    static func draw(_ watermark: WatermarkConfiguration?, in context: CGContext, bounds: CGRect) {
        guard let watermark,
              watermark.opacity > 0,
              let stampSize = stampSize(for: watermark, bounds: bounds) else { return }

        if watermark.placement == .tiled {
            drawTiled(watermark, stampSize: stampSize, in: context, bounds: bounds)
        } else {
            drawStamp(watermark, in: placementRect(watermark.placement, stampSize: stampSize, bounds: bounds), context: context)
        }
    }

    private static func stampSize(for watermark: WatermarkConfiguration, bounds: CGRect) -> CGSize? {
        switch watermark.kind {
        case .text:
            guard !watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let baseFontSize = max(14, min(bounds.width, bounds.height) * watermark.sizePercent.clamped(to: 5...50) / 100 * 0.35)
            let line = textLine(watermark, fontSize: baseFontSize)
            let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let maxWidth = bounds.width * 0.7
            let scale = lineBounds.width > maxWidth ? maxWidth / lineBounds.width : 1
            return CGSize(width: ceil(lineBounds.width * scale), height: ceil(lineBounds.height * scale))
        case .image:
            guard let data = watermark.imageData,
                  let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  image.width > 0, image.height > 0 else { return nil }
            let targetWidth = bounds.width * watermark.sizePercent.clamped(to: 5...50) / 100
            var size = CGSize(width: targetWidth, height: targetWidth * CGFloat(image.height) / CGFloat(image.width))
            if size.height > bounds.height * 0.5 {
                let scale = bounds.height * 0.5 / size.height
                size.width *= scale
                size.height *= scale
            }
            return size
        }
    }

    private static func placementRect(_ placement: WatermarkPlacement, stampSize: CGSize, bounds: CGRect) -> CGRect {
        let margin = max(12, min(bounds.width, bounds.height) * 0.025)
        let left = bounds.minX + margin
        let centerX = bounds.midX - stampSize.width / 2
        let right = bounds.maxX - margin - stampSize.width
        let bottom = bounds.minY + margin
        let centerY = bounds.midY - stampSize.height / 2
        let top = bounds.maxY - margin - stampSize.height

        let origin: CGPoint = switch placement {
        case .topLeft: CGPoint(x: left, y: top)
        case .top: CGPoint(x: centerX, y: top)
        case .topRight: CGPoint(x: right, y: top)
        case .left: CGPoint(x: left, y: centerY)
        case .center: CGPoint(x: centerX, y: centerY)
        case .right: CGPoint(x: right, y: centerY)
        case .bottomLeft: CGPoint(x: left, y: bottom)
        case .bottom: CGPoint(x: centerX, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        case .tiled: CGPoint(x: left, y: bottom)
        }
        return CGRect(origin: origin, size: stampSize)
    }

    private static func drawTiled(
        _ watermark: WatermarkConfiguration,
        stampSize: CGSize,
        in context: CGContext,
        bounds: CGRect
    ) {
        let gapX = max(36, stampSize.width * 0.65)
        let gapY = max(32, stampSize.height * 1.4)
        var row = 0
        var y = bounds.minY + gapY / 2
        while y < bounds.maxY {
            var x = bounds.minX + gapX / 2 - (row.isMultiple(of: 2) ? 0 : (stampSize.width + gapX) / 2)
            while x < bounds.maxX {
                drawStamp(
                    watermark,
                    in: CGRect(x: x, y: y, width: stampSize.width, height: stampSize.height),
                    context: context
                )
                x += stampSize.width + gapX
            }
            y += stampSize.height + gapY
            row += 1
        }
    }

    private static func drawStamp(_ watermark: WatermarkConfiguration, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setAlpha(watermark.opacity.clamped(to: 0...1))
        switch watermark.kind {
        case .text:
            let baseFontSize = max(14, rect.height / 0.8)
            let line = textLine(watermark, fontSize: baseFontSize)
            let lineBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let scale = min(1, rect.width / max(1, lineBounds.width), rect.height / max(1, lineBounds.height))
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.55).cgColor)
            context.textPosition = CGPoint(x: -lineBounds.minX, y: -lineBounds.minY)
            CTLineDraw(line, context)
        case .image:
            if let data = watermark.imageData,
               let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.interpolationQuality = .high
                context.draw(image, in: rect)
            }
        }
        context.restoreGState()
    }

    private static func textLine(_ watermark: WatermarkConfiguration, fontSize: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: watermark.textColor.nsColor
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: watermark.text, attributes: attributes))
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self { min(max(self, limits.lowerBound), limits.upperBound) }
}
