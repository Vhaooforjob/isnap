import AppKit
import ImageIO

struct DraftItem: Identifiable {
    let url: URL
    let modifiedAt: Date
    let bytes: Int64
    var id: URL { url }
    var name: String {
        let value = url.deletingPathExtension().lastPathComponent
        if value.count > 37, UUID(uuidString: String(value.suffix(36))) != nil {
            return String(value.dropLast(37))
        }
        return value
    }
}

actor DraftCatalog {
    static let shared = DraftCatalog()
    private var thumbnails: [String: CGImage] = [:]

    func items(in directory: URL = ProjectStore.directory) throws -> [DraftItem] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            .filter { $0.pathExtension == "isnap" && !["Latest.isnap", "Previous.isnap"].contains($0.lastPathComponent) }
            .compactMap {
                let values = try $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return DraftItem(url: $0, modifiedAt: values.contentModificationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0))
            }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func thumbnail(_ url: URL) throws -> CGImage? {
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let values = try refreshedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
        if let cached = thumbnails[key] { return cached }
        let project = try ProjectStore.read(url)
        guard let source = NSImage(data: project.image) else { return nil }
        // Show edits and privacy masks, not the unedited source stored in the project.
        let rendered = try ExportRenderer.render(RenderRequest(image: source, annotations: project.annotations,
            canvas: project.canvas, includeBackground: true,
            backgroundImage: project.backgroundImage.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
            maxPixelDimension: 240)
        let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if thumbnails.count >= 80 { thumbnails.removeAll() }
        thumbnails[key] = cg
        return cg
    }

    func rename(_ url: URL, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        var project = try ProjectStore.read(url)
        project.sourceName = clean
        let target = url.deletingLastPathComponent().appendingPathComponent("\(clean.prefix(80))-\(UUID()).isnap")
        try ProjectStore.writeDraft(project, to: target)
        do { try FileManager.default.removeItem(at: url) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
    }

    func trash(_ urls: [URL]) throws {
        for url in urls where !["Latest.isnap", "Previous.isnap"].contains(url.lastPathComponent) {
            try ProjectStore.draftLock.withLock {
                // Make a trashed draft portable so restoring it never depends on collected assets.
                let project = try ProjectStore.read(url)
                try ProjectStore.write(project, to: url)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        for folder in Set(urls.map { $0.deletingLastPathComponent() }) { try ProjectStore.collectAssets(in: folder) }
    }

    func prune(days: Int, directory: URL = ProjectStore.directory, now: Date = Date()) throws {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        try trash(items(in: directory).filter { $0.modifiedAt < cutoff }.map(\.url))
    }
}
