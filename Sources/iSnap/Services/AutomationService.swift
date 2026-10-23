import AppKit
import AppIntents
import UniformTypeIdentifiers

@MainActor
enum AutomationContext {
    static weak var model: AppModel?
    static var features: WorkspaceFeatures { model?.features ?? WorkspaceFeatures() }
}

enum AutomationError: LocalizedError {
    case busy, unavailable, missingPreset, missingWorkflow, invalidSize, draftPreservation
    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "iSnap is busy. Finish the current capture or export and try again.")
        case .unavailable: String(localized: "Open iSnap and try again.")
        case .missingPreset: String(localized: "This preset no longer exists. Choose another preset in Shortcuts.")
        case .missingWorkflow: String(localized: "This workflow no longer exists. Choose another workflow in Shortcuts.")
        case .invalidSize: String(localized: "Maximum dimension must be 0 (original size) or between 1 and 16384 pixels.")
        case .draftPreservation: String(localized: "The current draft could not be preserved. Check iSnap before trying again.")
        }
    }
}

struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Canvas Preset"
    static var defaultQuery = PresetQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct PresetQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [PresetEntity] {
        AutomationContext.features.state.presets.map { PresetEntity(id: $0.id, name: $0.name) }
    }
}
struct WorkflowEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Workflow"
    static var defaultQuery = WorkflowQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WorkflowQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [WorkflowEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [WorkflowEntity] {
        (AutomationContext.features.state.workflows ?? []).map { WorkflowEntity(id: $0.id, name: $0.name) }
    }
}

enum ShortcutImageFormat: String, AppEnum {
    case png, jpeg
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static var caseDisplayRepresentations: [ShortcutImageFormat: DisplayRepresentation] = [.png: "PNG", .jpeg: "JPEG"]
}

actor AutomationImageService {
    func extract(_ data: Data) async throws -> String {
        let image = try decode(data)
        return try await ScreenshotParserService().parse(image).text
    }

    func export(_ data: Data, canvas: CanvasConfiguration, maxDimension: Int, format: ShortcutImageFormat, background: Data? = nil) async throws -> Data {
        guard (0...16_384).contains(maxDimension) else { throw AutomationError.invalidSize }
        let image = try decode(data)
        try Task.checkCancellation()
        return try autoreleasepool {
            let source = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            let backgroundImage = try background.map { try decode($0) }
            let rendered = try ExportRenderer.render(RenderRequest(image: source, annotations: [], canvas: canvas, includeBackground: true, backgroundImage: backgroundImage),
                maxPixelDimension: maxDimension == 0 ? nil : maxDimension)
            try Task.checkCancellation()
            guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: format == .png ? .png : .jpeg,
                    properties: format == .jpeg ? [.compressionFactor: 0.95] : [:]) else { throw ExportError.encodingFailed }
            return data
        }
    }

    private func decode(_ data: Data) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 60_000, height <= 60_000, width * height <= 80_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw ExportError.invalidImage }
        return image
    }
}

struct ExtractScreenshotTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Text from Image"
    static var description = IntentDescription("Recognize English and Vietnamese text on your Mac.")
    @Parameter(title: "Image") var image: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Extract text from \(\.$image)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await AutomationImageService().extract(image.data))
    }
}

struct ExportScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Style and Export Image"
    static var description = IntentDescription("Apply an optional iSnap preset, resize and return a PNG or JPEG file. Use Save File in Shortcuts to choose where to save it.")
    @Parameter(title: "Image") var image: IntentFile
    @Parameter(title: "Preset") var preset: PresetEntity?
    @Parameter(title: "Maximum Dimension", default: 0) var maxDimension: Int
    @Parameter(title: "Format", default: .png) var format: ShortcutImageFormat
    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$image) as \(\.$format)") { \.$preset; \.$maxDimension }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
        var background: Data?
        if let preset {
            guard let saved = AutomationContext.features.state.presets.first(where: { $0.id == preset.id }) else { throw AutomationError.missingPreset }
            canvas = saved.canvas
            background = saved.backgroundImage
        }
        let data = try await AutomationImageService().export(image.data, canvas: canvas, maxDimension: maxDimension, format: format, background: background)
        let name = URL(fileURLWithPath: image.filename).deletingPathExtension().lastPathComponent
        return .result(value: IntentFile(data: data, filename: "\(name)-edited.\(format.rawValue)", type: format == .png ? .png : .jpeg))
    }
}

struct RunCaptureWorkflowIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Capture Workflow"
    static var description = IntentDescription("Run a saved iSnap workflow and return the captured image.")
    static var openAppWhenRun = true
    @Parameter(title: "Workflow") var workflow: WorkflowEntity
    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$workflow)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let model = AutomationContext.model else { throw AutomationError.unavailable }
        guard let saved = model.features.state.workflows?.first(where: { $0.id == workflow.id }) else { throw AutomationError.missingWorkflow }
        let format = model.settings.value.export.defaultFormat
        let task = try model.startWorkflow(saved)
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
            task.cancel()
            Task { @MainActor in model.regionCoordinator.cancelSelection() }
        })
        return .result(value: IntentFile(data: result.data, filename: "iSnap.\(format.fileExtension)", type: format == .png ? .png : .jpeg))
    }
}

struct ISnapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExtractScreenshotTextIntent(), phrases: ["Extract image text with \(.applicationName)"],
            shortTitle: "Extract Text", systemImageName: "text.viewfinder")
        AppShortcut(intent: ExportScreenshotIntent(), phrases: ["Style an image with \(.applicationName)"],
            shortTitle: "Style Image", systemImageName: "photo")
        AppShortcut(intent: RunCaptureWorkflowIntent(), phrases: ["Run a capture workflow with \(.applicationName)"],
            shortTitle: "Capture Workflow", systemImageName: "camera.viewfinder")
    }
}
