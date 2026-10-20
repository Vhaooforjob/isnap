import AppKit

struct ImageRenderSnapshot {
    let image: CGImage
    let annotations: [Annotation]
    let canvas: CanvasConfiguration
    let includeBackground: Bool
}

struct RenderedExport {
    let image: CGImage
    let data: Data
}

actor BackgroundExportService {
    func render(_ snapshot: ImageRenderSnapshot, format: ExportFormat, quality: Double) throws -> RenderedExport {
        try Task.checkCancellation()
        return try autoreleasepool {
            let source = NSImage(cgImage: snapshot.image, size: CGSize(width: snapshot.image.width, height: snapshot.image.height))
            let image = try ExportRenderer.render(RenderRequest(image: source, annotations: snapshot.annotations,
                canvas: snapshot.canvas, includeBackground: snapshot.includeBackground))
            try Task.checkCancellation()
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: format == .png ? .png : .jpeg,
                    properties: format == .jpeg ? [.compressionFactor: quality.clamped(to: 0...1)] : [:]) else { throw ExportError.encodingFailed }
            try Task.checkCancellation()
            return RenderedExport(image: cg, data: data)
        }
    }

    func write(_ data: Data, to url: URL, overwrite: Bool = false) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
    }

    func quickSave(_ data: Data, settings: AppSettings) throws -> URL {
        let folder = settings.quickSave.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = settings.quickSave.pattern == .date ? "yyyy-MM-dd" : "yyyyMMdd-HHmmss"
        var base = "iSnap-\(formatter.string(from: Date()))"
        if settings.quickSave.pattern == .increment {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let next = files.compactMap { Int($0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "iSnap-", with: "")) }.max().map { $0 + 1 } ?? 1
            base = String(format: "iSnap-%04d", next)
        }
        let ext = settings.export.defaultFormat.fileExtension
        var target = folder.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base)-\(suffix).\(ext)"); suffix += 1
        }
        try write(data, to: target)
        return target
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let changed: @Sendable (Double) -> Void
    init(_ changed: @escaping @Sendable (Double) -> Void) { self.changed = changed }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { changed(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}

struct UploadHistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let provider: String
    let url: URL
}

enum UploadHistoryStore {
    static let url = StorageService.appSupport.appendingPathComponent("UploadHistory.json")
    static func read() -> [UploadHistoryEntry] {
        (try? JSONDecoder().decode([UploadHistoryEntry].self, from: Data(contentsOf: url))) ?? []
    }
    static func save(_ entries: [UploadHistoryEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(entries.prefix(100))).write(to: url, options: .atomic)
    }
}
