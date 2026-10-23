import AppKit
import Combine
import Foundation

@MainActor
final class EditorDocument: ObservableObject {
    struct AnnotationEditRequest: Identifiable, Equatable {
        let id: UUID
        let checkpointOnCommit: Bool
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var sourceName = "Untitled"
    @Published var annotations: [Annotation] = []
    @Published var selectedAnnotationID: UUID? {
        didSet { selectedAnnotationIDs = selectedAnnotationID.map { [$0] } ?? [] }
    }
    @Published private(set) var selectedAnnotationIDs: Set<UUID> = []
    @Published var sampledColor = ""
    private var samplingTask: Task<Void, Never>?
    @Published var tool = EditorTool.select
    @Published var snappingEnabled = true
    @Published var style = AnnotationStyle()
    @Published var canvas = CanvasConfiguration()
    @Published var cropAspectRatio = CropAspectRatio.free
    @Published var cropRect: CGRect?
    @Published private(set) var previewZoom: CGFloat = 1
    @Published var annotationEditRequest: AnnotationEditRequest?
    @Published private(set) var isCropApplied = false
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isDirty = false {
        didSet { if isDirty { revision &+= 1 } }
    }

    private var originalImage: NSImage?
    private var originalAnnotations: [Annotation] = []
    private var lastAppliedCrop: CGRect?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let historyLimit = 100
    private var snapshotImages: [(NSImage, CGImage)] = []

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
        previewZoom = 1
        annotationEditRequest = nil
        revision &+= 1
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
        guard !annotations[index].isLocked else { return }
        if shouldCheckpoint { checkpoint() }
        annotations[index] = annotation
        isDirty = true
    }

    func addPrivacyMasks(_ frames: [CGRect]) {
        guard !frames.isEmpty else { return }
        checkpoint()
        annotations.append(contentsOf: frames.map { Annotation(type: .redact, frame: $0) })
        selectedAnnotationID = annotations.last?.id
        tool = .select
        isDirty = true
    }

    func beginMutation() { checkpoint() }

    func select(_ id: UUID?, extending: Bool = false) {
        guard extending, let id else { selectedAnnotationID = id; return }
        var ids = selectedAnnotationIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        selectedAnnotationID = ids.contains(id) ? id : annotations.last(where: { ids.contains($0.id) })?.id
        selectedAnnotationIDs = ids
    }

    func selectAllAnnotations() {
        selectedAnnotationID = annotations.last?.id
        selectedAnnotationIDs = Set(annotations.map(\.id))
    }

    func moveSelection(dx: CGFloat, dy: CGFloat, checkpoint shouldCheckpoint: Bool = true) {
        guard !selectedAnnotationIDs.isEmpty, dx != 0 || dy != 0 else { return }
        if shouldCheckpoint { checkpoint() }
        for index in annotations.indices where selectedAnnotationIDs.contains(annotations[index].id) && !annotations[index].isLocked && !annotations[index].isHidden {
            annotations[index].frame.origin.x += dx
            annotations[index].frame.origin.y += dy
        }
        isDirty = true
    }

    func duplicateSelection() {
        let selected = annotations.filter { selectedAnnotationIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        checkpoint()
        var number = annotations.compactMap(\.number).max() ?? 0
        let copies = selected.map { item -> Annotation in
            var copy = item
            copy.id = UUID()
            copy.frame.origin.x += 10; copy.frame.origin.y += 10
            if copy.type == .number { number += 1; copy.number = number }
            return copy
        }
        annotations.append(contentsOf: copies)
        selectedAnnotationID = copies.last?.id
        selectedAnnotationIDs = Set(copies.map(\.id))
        isDirty = true
    }

    func reorderSelection(toFront: Bool) {
        let selected = annotations.filter { selectedAnnotationIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let others = annotations.filter { !selectedAnnotationIDs.contains($0.id) }
        let reordered = toFront ? others + selected : selected + others
        guard reordered != annotations else { return }
        checkpoint()
        annotations = reordered
        isDirty = true
    }

    enum Alignment: String, CaseIterable, Identifiable {
        case left, center, right, top, middle, bottom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: String(localized: "Align Left")
            case .center: String(localized: "Align Centers")
            case .right: String(localized: "Align Right")
            case .top: String(localized: "Align Top")
            case .middle: String(localized: "Align Middles")
            case .bottom: String(localized: "Align Bottom")
            }
        }
    }

    func alignSelection(_ alignment: Alignment) {
        let selected = annotations.filter { selectedAnnotationIDs.contains($0.id) && !$0.isLocked && !$0.isHidden }
        guard selected.count > 1 else { return }
        let bounds = selected.reduce(CGRect.null) { $0.union($1.normalizedFrame) }
        checkpoint()
        for index in annotations.indices where selectedAnnotationIDs.contains(annotations[index].id) && !annotations[index].isLocked && !annotations[index].isHidden {
            let frame = annotations[index].normalizedFrame
            switch alignment {
            case .left: annotations[index].frame.origin.x += bounds.minX - frame.minX
            case .center: annotations[index].frame.origin.x += bounds.midX - frame.midX
            case .right: annotations[index].frame.origin.x += bounds.maxX - frame.maxX
            case .top: annotations[index].frame.origin.y += bounds.minY - frame.minY
            case .middle: annotations[index].frame.origin.y += bounds.midY - frame.midY
            case .bottom: annotations[index].frame.origin.y += bounds.maxY - frame.maxY
            }
        }
        isDirty = true
    }

    func deleteSelection() {
        let ids = Set(annotations.filter { selectedAnnotationIDs.contains($0.id) && !$0.isLocked }.map(\.id))
        guard !ids.isEmpty else { return }
        checkpoint()
        annotations.removeAll { ids.contains($0.id) }
        selectedAnnotationID = nil
        if let id = annotationEditRequest?.id, ids.contains(id) { annotationEditRequest = nil }
        isDirty = true
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll { !$0.isLocked }
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
            translated.magnifierSource = item.magnifierSource?.offsetBy(dx: -clipped.minX, dy: -clipped.minY)
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

    func updateLayer(_ id: UUID, name: String? = nil, hidden: Bool? = nil, locked: Bool? = nil) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        if let name { annotations[index].layerName = name }
        if let hidden { annotations[index].hidden = hidden }
        if let locked { annotations[index].locked = locked }
        isDirty = true
    }

    func moveLayer(_ id: UUID, before target: UUID) {
        guard id != target, let source = annotations.firstIndex(where: { $0.id == id }),
              let destination = annotations.firstIndex(where: { $0.id == target }) else { return }
        checkpoint()
        let item = annotations.remove(at: source)
        annotations.insert(item, at: destination)
        isDirty = true
    }

    func setFrame(_ frame: CGRect, for id: UUID) {
        guard var item = annotations.first(where: { $0.id == id }), !item.isLocked,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= 1, frame.height >= 1, frame.width <= 100_000, frame.height <= 100_000 else { return }
        let previous = item.normalizedFrame
        item.points = item.points.map { CGPoint(x: $0.x * frame.width / max(1, previous.width),
                                               y: $0.y * frame.height / max(1, previous.height)) }
        item.frame = frame
        update(item, checkpoint: true)
    }

    func project() throws -> EditorProject {
        guard let image else { throw ExportError.invalidImage }
        return try EditorProject(sourceName: sourceName, image: ProjectStore.png(image),
            originalImage: originalImage === image ? nil : originalImage.map(ProjectStore.png), annotations: annotations,
            originalAnnotations: originalAnnotations, canvas: canvas,
            backgroundImage: canvas.backgroundImageURL.map { try Data(contentsOf: $0) },
            cropRect: cropRect, lastAppliedCrop: lastAppliedCrop, isCropApplied: isCropApplied)
    }

    func projectSnapshot() throws -> ProjectSnapshot {
        guard let image else { throw ExportError.invalidImage }
        func bitmap(_ value: NSImage) throws -> CGImage {
            if let cached = snapshotImages.first(where: { $0.0 === value }) { return cached.1 }
            guard let cg = value.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
            snapshotImages.append((value, cg))
            if snapshotImages.count > 2 { snapshotImages.removeFirst() }
            return cg
        }
        return try ProjectSnapshot(image: bitmap(image),
            originalImage: originalImage === image ? nil : originalImage.map(bitmap),
            project: EditorProject(sourceName: sourceName, image: Data(), annotations: annotations,
                originalAnnotations: originalAnnotations, canvas: canvas, cropRect: cropRect,
                lastAppliedCrop: lastAppliedCrop, isCropApplied: isCropApplied))
    }

    func loadProject(_ project: EditorProject) throws {
        guard project.version == 1 else { throw ProjectError.unsupportedVersion }
        guard let image = NSImage(data: project.image) else { throw ExportError.invalidImage }
        let original = project.originalImage.flatMap(NSImage.init(data:))
        if project.originalImage != nil && original == nil { throw ExportError.invalidImage }
        var configuration = project.canvas
        if let data = project.backgroundImage {
            let folder = ProjectStore.directory.deletingLastPathComponent().appendingPathComponent("Project Backgrounds")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Content-addressed imports keep repeated draft restoration bounded.
            let url = folder.appendingPathComponent(ProjectAsset.digest(data) + ".png")
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            configuration.backgroundImageURL = url
        }
        load(CaptureResult(image: image, sourceName: project.sourceName))
        originalImage = original ?? image
        annotations = project.annotations
        originalAnnotations = project.originalAnnotations
        canvas = configuration
        cropRect = project.cropRect
        lastAppliedCrop = project.lastAppliedCrop
        isCropApplied = project.isCropApplied
    }

    func presentEditor(for annotation: Annotation, checkpointOnCommit: Bool = true) {
        guard !annotation.isLocked, annotation.type == .text || annotation.type == .number else { return }
        selectedAnnotationID = annotation.id
        annotationEditRequest = AnnotationEditRequest(
            id: annotation.id,
            checkpointOnCommit: checkpointOnCommit
        )
    }

    func presentEditorForSelection() {
        guard let annotation = selectedAnnotation else { return }
        presentEditor(for: annotation)
    }

    func commitEditor(_ annotation: Annotation) {
        guard let request = annotationEditRequest, request.id == annotation.id else { return }
        update(annotation, checkpoint: request.checkpointOnCommit)
        if annotation.type == .number { style.markerStyle = annotation.markerStyle }
        annotationEditRequest = nil
    }

    func cancelEditor() {
        annotationEditRequest = nil
    }

    func setPreviewZoom(_ value: CGFloat) {
        previewZoom = value.clamped(to: 0.25...4)
    }

    func zoomPreviewIn() {
        setPreviewZoom(previewZoom * 1.25)
    }

    func zoomPreviewOut() {
        setPreviewZoom(previewZoom / 1.25)
    }

    func resetPreviewZoom() {
        previewZoom = 1
    }

    func applyCutOut(_ result: CutOutResult) {
        checkpoint()
        image = NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height))
        annotations = result.annotations; cropRect = nil; isCropApplied = false
        originalImage = nil; originalAnnotations = []; lastAppliedCrop = nil
        selectedAnnotationID = nil; isDirty = true
    }

    func sampleColor(at point: CGPoint) {
        samplingTask?.cancel()
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let annotations = annotations
        samplingTask = Task {
            do {
                let rendered = try await BackgroundExportService().render(ImageRenderSnapshot(image: cg,
                    annotations: annotations, canvas: .sourcePixels, includeBackground: false), format: .png, quality: 1)
                try Task.checkCancellation()
                guard self.image === image, self.annotations == annotations else { return }
                sampledColor = try PixelSample.read(rendered.image, at: point).description
            } catch is CancellationError {} catch { sampledColor = error.localizedDescription }
        }
    }

    func eraseStrokes(at point: CGPoint, radius: CGFloat) {
        var updated: [Annotation] = []
        for item in annotations {
            guard item.type.isStroke, !item.isHidden, !item.isLocked else { updated.append(item); continue }
            let points = StrokeGeometry.worldPoints(item)
            let pieces = StrokeGeometry.erase(points, center: point, radius: radius + item.strokeWidth / 2)
            if pieces == [points] { updated.append(item); continue }
            for (index, piece) in pieces.enumerated() {
                let geometry = Annotation.freehand(piece, style: style)
                var part = item
                part.id = index == 0 ? item.id : UUID()
                part.frame = geometry.frame; part.points = geometry.points; part.rotation = 0
                updated.append(part)
            }
        }
        if updated != annotations { annotations = updated; isDirty = true; selectedAnnotationID = nil }
    }

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
