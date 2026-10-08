import AppKit
import SwiftUI

struct EditorCanvasHost: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        EditorCanvas(document: document)
            .sheet(item: $document.annotationEditRequest) { request in
                AnnotationEditorSheet(document: document, request: request)
            }
    }
}

private struct AnnotationEditorSheet: View {
    private enum Field: Hashable { case text, markerValue }

    @ObservedObject var document: EditorDocument
    let request: EditorDocument.AnnotationEditRequest
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var text: String
    @State private var markerStyle: Annotation.MarkerStyle
    @State private var markerValue: Int

    init(document: EditorDocument, request: EditorDocument.AnnotationEditRequest) {
        self.document = document
        self.request = request
        let annotation = document.annotations.first { $0.id == request.id }
        _text = State(initialValue: annotation?.text ?? "")
        _markerStyle = State(initialValue: annotation?.markerStyle ?? .number)
        _markerValue = State(initialValue: max(1, annotation?.number ?? 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if annotation?.type == .number {
                Text("Edit marker").font(.title3.weight(.semibold))
                Picker("Marker style", selection: $markerStyle) {
                    ForEach(Annotation.MarkerStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Sequence value")
                    TextField("Value", value: $markerValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .focused($focusedField, equals: .markerValue)
                    Stepper("", value: $markerValue, in: 1...9999)
                        .labelsHidden()
                    Spacer()
                    Text(markerPreview)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color(nsColor: annotation?.stroke.nsColor ?? .systemRed)))
                }
            } else {
                Text("Edit text").font(.title3.weight(.semibold))
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .focused($focusedField, equals: .text)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(annotation?.type == .text && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            focusedField = annotation?.type == .number ? .markerValue : .text
        }
    }

    private var annotation: Annotation? {
        document.annotations.first { $0.id == request.id }
    }

    private var markerPreview: String {
        var preview = Annotation(type: .number, frame: .zero)
        preview.markerStyle = markerStyle
        preview.number = max(1, markerValue)
        return preview.markerLabel
    }

    private func apply() {
        guard var value = annotation else {
            cancel()
            return
        }
        if value.type == .text {
            value.text = text
        } else if value.type == .number {
            value.markerStyle = markerStyle
            value.number = max(1, markerValue)
        }
        document.commitEditor(value)
        dismiss()
    }

    private func cancel() {
        document.cancelEditor()
        dismiss()
    }
}

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var document: EditorDocument

    func makeNSView(context: Context) -> InteractiveCanvasView {
        let view = InteractiveCanvasView()
        view.document = document
        return view
    }

    func updateNSView(_ view: InteractiveCanvasView, context: Context) {
        view.document = document
        view.updatePreviewZoom(document.previewZoom)
        view.needsDisplay = true
        view.needsLayout = true
    }
}

@MainActor
final class InteractiveCanvasView: NSView {
    private enum DragHandle {
        case boundsBottomRight
        case lineStart
        case lineEnd
    }

    weak var document: EditorDocument?
    private var dragStart: CGPoint?
    private var originalAnnotation: Annotation?
    private var temporaryAnnotation: Annotation?
    private var dragHandle: DragHandle?
    private var didCheckpointDrag = false
    private var panOffset = CGPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func updatePreviewZoom(_ zoom: CGFloat) {
        if zoom <= 1 { panOffset = .zero }
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
        let rect = previewRect(for: rendered.size, zoom: document.previewZoom)
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
        dragHandle = nil

        if document.tool == .select {
            let hit = document.annotations.reversed().first { annotation in
                annotation.normalizedFrame.insetBy(dx: -8, dy: -8).contains(point)
            }
            document.selectedAnnotationID = hit?.id
            originalAnnotation = hit
            if let hit {
                let tolerance = selectionTolerance(document: document)
                if hit.type == .line || hit.type == .arrow {
                    if distance(hit.lineStartPoint, point) <= tolerance {
                        dragHandle = .lineStart
                    } else if distance(hit.lineEndPoint, point) <= tolerance {
                        dragHandle = .lineEnd
                    }
                } else {
                    let handle = CGPoint(x: hit.normalizedFrame.maxX, y: hit.normalizedFrame.maxY)
                    if distance(handle, point) <= tolerance { dragHandle = .boundsBottomRight }
                }
                if event.clickCount == 2, hit.type == .text || hit.type == .number {
                    document.presentEditor(for: hit)
                }
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
            if dragHandle == .lineStart {
                annotation.setLineEndpoints(start: point, end: originalAnnotation!.lineEndPoint)
            } else if dragHandle == .lineEnd {
                annotation.setLineEndpoints(start: originalAnnotation!.lineStartPoint, end: point)
            } else if dragHandle == .boundsBottomRight {
                let frame = originalAnnotation!.normalizedFrame
                if annotation.type == .image, frame.height > 0 {
                    let aspectRatio = frame.width / frame.height
                    let width = max(24, point.x - frame.minX)
                    annotation.frame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: width,
                        height: max(24, width / aspectRatio)
                    )
                } else {
                    annotation.frame = CGRect(
                        x: frame.minX,
                        y: frame.minY,
                        width: max(12, point.x - frame.minX),
                        height: max(12, point.y - frame.minY)
                    )
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
            if value.type == .text {
                let frame = value.normalizedFrame
                if frame.width < 24 || frame.height < 24 {
                    let width = max(180, document.style.fontSize * 6)
                    let height = max(44, document.style.fontSize * 1.6)
                    value.frame = CGRect(origin: value.frame.origin, size: CGSize(width: width, height: height))
                } else {
                    value.frame = frame
                }
            } else if value.type == .number {
                let size = max(36, max(abs(value.frame.width), abs(value.frame.height)))
                value.frame = CGRect(x: value.frame.minX, y: value.frame.minY, width: size, height: size)
            }
            if value.normalizedFrame.width >= 3 || value.normalizedFrame.height >= 3 {
                document.add(value)
                if (value.type == .text || value.type == .number),
                   let added = document.selectedAnnotation {
                    document.presentEditor(for: added, checkpointOnCommit: false)
                }
            }
        }
        dragStart = nil
        originalAnnotation = nil
        temporaryAnnotation = nil
        dragHandle = nil
        didCheckpointDrag = false
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let document else { return }
        document.setPreviewZoom(document.previewZoom * max(0.1, 1 + event.magnification))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let document, document.previewZoom > 1,
              let geometry = renderGeometry(document: document) else {
            super.scrollWheel(with: event)
            return
        }
        let limits = panLimits(for: geometry.output, zoom: document.previewZoom)
        panOffset.x = (panOffset.x - event.scrollingDeltaX).clamped(to: -limits.x...limits.x)
        panOffset.y = (panOffset.y - event.scrollingDeltaY).clamped(to: -limits.y...limits.y)
        needsDisplay = true
        needsLayout = true
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

    private func constrainedRect(from start: CGPoint, to end: CGPoint, ratio: CGFloat?) -> CGRect {
        guard let ratio else {
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        let width = abs(end.x - start.x)
        let height = width / ratio
        return CGRect(x: end.x < start.x ? start.x - width : start.x, y: end.y < start.y ? start.y - height : start.y, width: width, height: height)
    }

    private func previewRect(for imageSize: CGSize, zoom: CGFloat) -> CGRect {
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard imageSize.width > 0, imageSize.height > 0 else { return available }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let limits = panLimits(for: imageSize, zoom: zoom)
        let offset = zoom > 1 ? CGPoint(
            x: panOffset.x.clamped(to: -limits.x...limits.x),
            y: panOffset.y.clamped(to: -limits.y...limits.y)
        ) : .zero
        return CGRect(
            x: available.midX - size.width / 2 + offset.x,
            y: available.midY - size.height / 2 + offset.y,
            width: size.width,
            height: size.height
        )
    }

    private func panLimits(for imageSize: CGSize, zoom: CGFloat) -> CGPoint {
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height) * zoom
        return CGPoint(
            x: max(0, (imageSize.width * scale - available.width) / 2),
            y: max(0, (imageSize.height * scale - available.height) / 2)
        )
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
        let preview = previewRect(for: geometry.output, zoom: document.previewZoom)
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
        let points: [CGPoint]
        if annotation.type == .line || annotation.type == .arrow {
            points = [annotation.lineStartPoint, annotation.lineEndPoint].compactMap {
                viewPoint(from: $0, document: document, previewRect: previewRect, renderedSize: renderedSize)
            }
        } else {
            points = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
            ]
        }
        for point in points {
            let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            handle.fill(); handle.stroke()
        }
    }

    private func viewPoint(
        from sourcePoint: CGPoint,
        document: EditorDocument,
        previewRect: CGRect,
        renderedSize: CGSize
    ) -> CGPoint? {
        guard let geometry = renderGeometry(document: document) else { return nil }
        let imageRect = geometry.imageRect
        let outputPoint = CGPoint(
            x: imageRect.minX + sourcePoint.x / document.imagePixelSize.width * imageRect.width,
            y: imageRect.minY + sourcePoint.y / document.imagePixelSize.height * imageRect.height
        )
        return CGPoint(
            x: previewRect.minX + outputPoint.x / renderedSize.width * previewRect.width,
            y: previewRect.minY + outputPoint.y / renderedSize.height * previewRect.height
        )
    }

    private func selectionTolerance(document: EditorDocument) -> CGFloat {
        guard let geometry = renderGeometry(document: document) else { return 14 }
        let preview = previewRect(for: geometry.output, zoom: document.previewZoom)
        let sourceToViewScale = geometry.imageRect.width / document.imagePixelSize.width
            * preview.width / geometry.output.width
        return max(4, 12 / max(0.01, sourceToViewScale))
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func drawCrop(_ crop: CGRect?, document: EditorDocument, previewRect: CGRect, renderedSize: CGSize) {
        guard let crop, let rect = viewRect(from: crop, document: document, previewRect: previewRect, renderedSize: renderedSize) else { return }
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawEmptyState() {
        let title = String(localized: "Capture, paste, or open an image")
        let subtitle = String(localized: "Use ⌃⌥1 for the screen under the pointer or ⌃⌥2 for a region")
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]
        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        title.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY - 20), withAttributes: titleAttributes)
        subtitle.draw(at: CGPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.midY + 14), withAttributes: subtitleAttributes)
    }
}
