import AppKit
import Combine
import Foundation

@MainActor
final class EditorDocument: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var sourceName = "Untitled"
    @Published var annotations: [Annotation] = []
    @Published var selectedAnnotationID: UUID?
    @Published var tool = EditorTool.select
    @Published var style = AnnotationStyle()
    @Published var canvas = CanvasConfiguration()
    @Published var cropAspectRatio = CropAspectRatio.free
    @Published var cropRect: CGRect?
    @Published private(set) var isCropApplied = false
    @Published private(set) var isDirty = false

    private var originalImage: NSImage?
    private var originalAnnotations: [Annotation] = []
    private var lastAppliedCrop: CGRect?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let historyLimit = 100

    struct Snapshot: Equatable {
        let image: NSImage?
        let annotations: [Annotation]
        let cropRect: CGRect?
        let canvas: CanvasConfiguration
        let isCropApplied: Bool
        let originalImage: NSImage?
        let originalAnnotations: [Annotation]
        let lastAppliedCrop: CGRect?

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.image === rhs.image &&
            lhs.annotations == rhs.annotations &&
            lhs.cropRect == rhs.cropRect &&
            lhs.canvas == rhs.canvas &&
            lhs.isCropApplied == rhs.isCropApplied &&
            lhs.originalImage === rhs.originalImage &&
            lhs.originalAnnotations == rhs.originalAnnotations &&
            lhs.lastAppliedCrop == rhs.lastAppliedCrop
        }
    }

    var imagePixelSize: CGSize {
        guard let image else { return .zero }
        if let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: bitmap.width, height: bitmap.height)
        }
        if let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    var selectedAnnotation: Annotation? {
        annotations.first { $0.id == selectedAnnotationID }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load(_ result: CaptureResult) {
        image = result.image
        originalImage = result.image
        sourceName = result.sourceName
        annotations = []
        originalAnnotations = []
        selectedAnnotationID = nil
        cropRect = nil
        lastAppliedCrop = nil
        isCropApplied = false
        isDirty = false
        undoStack = []
        redoStack = []
        tool = .select
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        var value = annotation
        if value.type == .number {
            value.number = (annotations.compactMap(\.number).max() ?? 0) + 1
        }
        annotations.append(value)
        selectedAnnotationID = value.id
        tool = .select
        isDirty = true
    }

    func update(_ annotation: Annotation, checkpoint shouldCheckpoint: Bool = false) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        if shouldCheckpoint { checkpoint() }
        annotations[index] = annotation
        isDirty = true
    }

    func beginMutation() { checkpoint() }

    func deleteSelection() {
        guard let id = selectedAnnotationID else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
        isDirty = true
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
        selectedAnnotationID = nil
        isDirty = true
    }

    func applyCrop() {
        guard let image, let cropRect, cropRect.width >= 2, cropRect.height >= 2,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        checkpoint()
        if !isCropApplied {
            originalImage = image
            originalAnnotations = annotations
        }
        let bounds = CGRect(origin: .zero, size: CGSize(width: source.width, height: source.height))
        let clipped = cropRect.intersection(bounds).integral
        let coreGraphicsRect = CGRect(
            x: clipped.minX,
            y: CGFloat(source.height) - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        guard let cropped = source.cropping(to: coreGraphicsRect) else { return }
        self.image = NSImage(cgImage: cropped, size: clipped.size)
        annotations = annotations.compactMap { item in
            guard item.normalizedFrame.intersects(clipped) else { return nil }
            var translated = item
            translated.frame.origin.x -= clipped.minX
            translated.frame.origin.y -= clipped.minY
            return translated
        }
        lastAppliedCrop = clipped
        self.cropRect = nil
        isCropApplied = true
        selectedAnnotationID = nil
        tool = .select
        isDirty = true
    }

    func resetCrop() {
        guard isCropApplied, let originalImage else { return }
        checkpoint()
        image = originalImage
        annotations = originalAnnotations
        cropRect = lastAppliedCrop
        isCropApplied = false
        selectedAnnotationID = nil
        isDirty = true
    }

    func updateCanvas(_ mutation: (inout CanvasConfiguration) -> Void) {
        checkpoint()
        mutation(&canvas)
        isDirty = true
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(snapshot)
    }

    func markSaved() { isDirty = false }

    private var currentSnapshot: Snapshot {
        Snapshot(
            image: image,
            annotations: annotations,
            cropRect: cropRect,
            canvas: canvas,
            isCropApplied: isCropApplied,
            originalImage: originalImage,
            originalAnnotations: originalAnnotations,
            lastAppliedCrop: lastAppliedCrop
        )
    }

    private func checkpoint() {
        let value = currentSnapshot
        guard undoStack.last != value else { return }
        undoStack.append(value)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ snapshot: Snapshot) {
        image = snapshot.image
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        canvas = snapshot.canvas
        isCropApplied = snapshot.isCropApplied
        originalImage = snapshot.originalImage
        originalAnnotations = snapshot.originalAnnotations
        lastAppliedCrop = snapshot.lastAppliedCrop
        selectedAnnotationID = nil
        isDirty = true
    }
}
