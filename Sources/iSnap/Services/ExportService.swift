import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ExportService {
    func render(document: EditorDocument, includeBackground: Bool) throws -> NSImage {
        guard let image = document.image else { throw ExportError.invalidImage }
        return try ExportRenderer.render(RenderRequest(
            image: image,
            annotations: document.annotations,
            canvas: document.canvas,
            includeBackground: includeBackground
        ))
    }

    func saveAs(document: EditorDocument, settings: AppSettings) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename(format: settings.export.defaultFormat)
        panel.allowedContentTypes = settings.export.defaultFormat == .png ? [.png] : [.jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let image = try render(document: document, includeBackground: settings.export.includeBackground)
        try encode(image, format: settings.export.defaultFormat, quality: settings.export.jpegQuality).write(to: url, options: .atomic)
        postSave(image: image, url: url, settings: settings)
        document.markSaved()
        return url
    }

    func quickSave(document: EditorDocument, settings: AppSettings) throws -> URL {
        let folder = settings.quickSave.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try render(document: document, includeBackground: settings.export.includeBackground)
        let filename = uniqueFilename(in: folder, pattern: settings.quickSave.pattern, format: settings.export.defaultFormat)
        let url = folder.appendingPathComponent(filename)
        try encode(image, format: settings.export.defaultFormat, quality: settings.export.jpegQuality).write(to: url, options: .atomic)
        postSave(image: image, url: url, settings: settings)
        document.markSaved()
        return url
    }

    func archiveCapture(_ image: NSImage, settings: AppSettings) throws -> URL {
        let folder = settings.quickSave.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "iSnap-Capture-\(Self.timestamp.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(suffix).png")
            suffix += 1
        }
        try encode(image, format: .png, quality: 1).write(to: url, options: .atomic)
        return url
    }

    func copy(document: EditorDocument, includeBackground: Bool) throws {
        copy(image: try render(document: document, includeBackground: includeBackground))
    }

    func encode(_ image: NSImage, format: ExportFormat, quality: Double) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.encodingFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
            ? [.compressionFactor: quality.clamped(to: 0...1)]
            : [:]
        guard let data = bitmap.representation(using: format == .png ? .png : .jpeg, properties: properties) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    private func postSave(image: NSImage, url: URL, settings: AppSettings) {
        if settings.export.autoCopyToClipboard { copy(image: image) }
        if settings.startup.showNotifications {
            NSSound(named: "Glass")?.play()
        }
    }

    private func copy(image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func suggestedFilename(format: ExportFormat) -> String {
        "iSnap-\(Self.timestamp.string(from: Date())).\(format.fileExtension)"
    }

    private func uniqueFilename(in folder: URL, pattern: FilenamePattern, format: ExportFormat) -> String {
        let base: String
        switch pattern {
        case .timestamp:
            base = "iSnap-\(Self.timestamp.string(from: Date()))"
        case .date:
            base = "iSnap-\(Self.date.string(from: Date()))"
        case .increment:
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let next = urls.compactMap { url -> Int? in
                let value = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "iSnap-", with: "")
                return Int(value)
            }.max().map { $0 + 1 } ?? 1
            base = String(format: "iSnap-%04d", next)
        }
        var url = folder.appendingPathComponent("\(base).\(format.fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(suffix).\(format.fileExtension)")
            suffix += 1
        }
        return url.lastPathComponent
    }

    private static let timestamp: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyyMMdd-HHmmss"
        return value
    }()

    private static let date: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()
}
