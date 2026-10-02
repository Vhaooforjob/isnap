import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeNSView(context: Context) -> InteractiveCanvasView {
        let view = InteractiveCanvasView()
        view.document = document
        return view
    }

    func updateNSView(_ view: InteractiveCanvasView, context: Context) {
        view.document = document
        view.needsDisplay = true
    }
}

@MainActor
final class InteractiveCanvasView: NSView {
    weak var document: EditorDocument?
    private var dragStart: CGPoint?
    private var originalAnnotation: Annotation?
    private var temporaryAnnotation: Annotation?
    private var isResizing = false
    private var didCheckpointDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let document, let image = document.image else {
            drawEmptyState()
            return
        }
        let annotations = temporaryAnnotation.map { document.annotations + [$0] } ?? document.annotations
        guard let rendered = try? ExportRenderer.render(RenderRequest(
            image: image,
            annotations: annotations,
            canvas: document.canvas,
            includeBackground: true
        )) else { return }
        let rect = previewRect(for: rendered.size)
        rendered.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        drawCrop(document.cropRect, document: document, previewRect: rect, renderedSize: rendered.size)
        drawSelection(document.selectedAnnotation, document: document, previewRect: rect, renderedSize: rendered.size)
    }

    override func mouseDown(with event: NSEvent) {
        guard let document, document.image != nil,
              let point = sourcePoint(from: convert(event.locationInWindow, from: nil), document: document) else { return }
        window?.makeFirstResponder(self)
        dragStart = point
        didCheckpointDrag = false

        if document.tool == .select {
            let hit = document.annotations.reversed().first { annotation in
                annotation.normalizedFrame.insetBy(dx: -8, dy: -8).contains(point)
            }
            document.selectedAnnotationID = hit?.id
            originalAnnotation = hit
            if let hit {
                let handle = CGPoint(x: hit.normalizedFrame.maxX, y: hit.normalizedFrame.maxY)
                isResizing = hypot(handle.x - point.x, handle.y - point.y) <= 14
                if event.clickCount == 2, hit.type == .text { editText(hit, document: document) }
            }
        } else if document.tool == .crop {
            document.cropRect = CGRect(origin: point, size: .zero)
        } else {
            temporaryAnnotation = Annotation.make(type: document.tool, from: point, to: point, style: document.style)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let start = dragStart,
              let point = sourcePoint(from: convert(event.locationInWindow, from: nil), document: document) else { return }
        if document.tool == .select, var annotation = originalAnnotation {
            if !didCheckpointDrag {
                document.beginMutation()
                didCheckpointDrag = true
            }
            if isResizing {
                annotation.frame.size = CGSize(
                    width: max(12, point.x - annotation.frame.minX),
                    height: max(12, point.y - annotation.frame.minY)
                )
                if annotation.type == .line || annotation.type == .arrow {
                    annotation.points = [.zero, CGPoint(x: annotation.frame.width, y: annotation.frame.height)]
                }
            } else {
                annotation.frame.origin = CGPoint(
                    x: originalAnnotation!.frame.origin.x + point.x - start.x,
                    y: originalAnnotation!.frame.origin.y + point.y - start.y
                )
            }
            document.update(annotation)
        } else if document.tool == .crop {
            document.cropRect = constrainedRect(from: start, to: point, ratio: document.cropAspectRatio.value)
        } else if temporaryAnnotation != nil {
            temporaryAnnotation = Annotation.make(type: document.tool, from: start, to: point, style: document.style)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let document else { return }
        if let annotation = temporaryAnnotation {
            var value = annotation
            if value.type == .number {
                let size = max(36, max(abs(value.frame.width), abs(value.frame.height)))
                value.frame = CGRect(x: value.frame.minX, y: value.frame.minY, width: size, height: size)
            }
            if value.normalizedFrame.width >= 3 || value.normalizedFrame.height >= 3 {
                document.add(value)
                if value.type == .text, let added = document.selectedAnnotation { editText(added, document: document) }
            }
        }
        dragStart = nil
        originalAnnotation = nil
        temporaryAnnotation = nil
        isResizing = false
        didCheckpointDrag = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let document else { return }
        if event.keyCode == 51 || event.keyCode == 117 {
            document.deleteSelection()
        } else if event.keyCode == 53 {
            document.selectedAnnotationID = nil
            document.cropRect = nil
            document.tool = .select
        } else {
            super.keyDown(with: event)
        }
    }

    private func editText(_ annotation: Annotation, document: EditorDocument) {
        let alert = NSAlert()
        alert.messageText = "Edit text"
        let field = NSTextField(string: annotation.text)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            var value = annotation
            value.text = field.stringValue
            document.update(value, checkpoint: true)
        }
    }

    private func constrainedRect(from start: CGPoint, to end: CGPoint, ratio: CGFloat?) -> CGRect {
        guard let ratio else {
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        let width = abs(end.x - start.x)
        let height = width / ratio
        return CGRect(x: end.x < start.x ? start.x - width : start.x, y: end.y < start.y ? start.y - height : start.y, width: width, height: height)
    }

    private func previewRect(for imageSize: CGSize) -> CGRect {
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard imageSize.width > 0, imageSize.height > 0 else { return available }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func renderGeometry(document: EditorDocument) -> (output: CGSize, imageRect: CGRect)? {
        let source = document.imagePixelSize
        guard source.width > 0, source.height > 0 else { return nil }
        let padding = document.canvas.showBackground ? document.canvas.padding : 0
        var output = CGSize(width: source.width + padding * 2, height: source.height + padding * 2)
        if let ratio = document.canvas.outputRatio.value {
            if output.width / output.height > ratio { output.height = output.width / ratio }
            else { output.width = output.height * ratio }
        }
        let available = CGRect(x: padding, y: padding, width: output.width - padding * 2, height: output.height - padding * 2)
        let insetScale = max(0.1, 1 - document.canvas.insetPercent / 100)
        let scale = min(available.width / source.width, available.height / source.height) * insetScale
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let imageRect = CGRect(x: (output.width - size.width) / 2, y: (output.height - size.height) / 2, width: size.width, height: size.height)
        return (output, imageRect)
    }

    private func sourcePoint(from viewPoint: CGPoint, document: EditorDocument) -> CGPoint? {
        guard let geometry = renderGeometry(document: document) else { return nil }
        let preview = previewRect(for: geometry.output)
        let outputPoint = CGPoint(
            x: (viewPoint.x - preview.minX) / preview.width * geometry.output.width,
            y: (viewPoint.y - preview.minY) / preview.height * geometry.output.height
        )
        guard geometry.imageRect.insetBy(dx: -10, dy: -10).contains(outputPoint) else { return nil }
        return CGPoint(
            x: (outputPoint.x - geometry.imageRect.minX) / geometry.imageRect.width * document.imagePixelSize.width,
            y: (outputPoint.y - geometry.imageRect.minY) / geometry.imageRect.height * document.imagePixelSize.height
        )
    }

    private func viewRect(from sourceRect: CGRect, document: EditorDocument, previewRect: CGRect, renderedSize: CGSize) -> CGRect? {
        guard let geometry = renderGeometry(document: document) else { return nil }
        let imageRect = geometry.imageRect
        let mapped = CGRect(
            x: imageRect.minX + sourceRect.minX / document.imagePixelSize.width * imageRect.width,
            y: imageRect.minY + sourceRect.minY / document.imagePixelSize.height * imageRect.height,
            width: sourceRect.width / document.imagePixelSize.width * imageRect.width,
            height: sourceRect.height / document.imagePixelSize.height * imageRect.height
        )
        return CGRect(
            x: previewRect.minX + mapped.minX / renderedSize.width * previewRect.width,
            y: previewRect.minY + mapped.minY / renderedSize.height * previewRect.height,
            width: mapped.width / renderedSize.width * previewRect.width,
            height: mapped.height / renderedSize.height * previewRect.height
        )
    }

    private func drawSelection(_ annotation: Annotation?, document: EditorDocument, previewRect: CGRect, renderedSize: CGSize) {
        guard let annotation, let rect = viewRect(from: annotation.normalizedFrame, document: document, previewRect: previewRect, renderedSize: renderedSize) else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            handle.fill(); handle.stroke()
        }
    }

    private func drawCrop(_ crop: CGRect?, document: EditorDocument, previewRect: CGRect, renderedSize: CGSize) {
        guard let crop, let rect = viewRect(from: crop, document: document, previewRect: previewRect, renderedSize: renderedSize) else { return }
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawEmptyState() {
        let title = "Capture, paste, or open an image"
        let subtitle = "Use ⌃⌥1 for all displays or ⌃⌥2 for a region"
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        title.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY - 20), withAttributes: titleAttributes)
        subtitle.draw(at: CGPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.midY + 14), withAttributes: subtitleAttributes)
    }
}

