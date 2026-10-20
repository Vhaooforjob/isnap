import AppKit
import Combine
import CryptoKit

enum ProjectAsset {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct CanvasPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var canvas: CanvasConfiguration
    var backgroundImage: Data?
}

struct LibraryMetadata: Codable {
    var favorite = false
    var tags: [String] = []
}

struct WorkspaceState: Codable {
    var presets: [CanvasPreset] = []
    var metadata: [String: LibraryMetadata] = [:]
    var captureDelay = 0
    var showsCursor = false
    var workflows: [CaptureWorkflow]?
}

@MainActor
final class WorkspaceFeatures: ObservableObject {
    @Published var state: WorkspaceState {
        didSet {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(state).write(to: url, options: .atomic)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    @Published var errorMessage: String?
    private let url: URL

    init(url: URL = ProjectStore.directory.deletingLastPathComponent().appendingPathComponent("Workspace.json")) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: url)) }
            catch { state = WorkspaceState(); errorMessage = error.localizedDescription }
        } else { state = WorkspaceState() }
    }

    func metadata(for url: URL) -> LibraryMetadata { state.metadata[url.standardizedFileURL.path] ?? LibraryMetadata() }
    func setMetadata(_ value: LibraryMetadata, for url: URL) { state.metadata[url.standardizedFileURL.path] = value }

    func setTags(_ tags: [String], for urls: [URL]) {
        var updated = state
        for url in urls {
            let path = url.standardizedFileURL.path
            var value = updated.metadata[path] ?? LibraryMetadata()
            value.tags = tags
            updated.metadata[path] = value
        }
        state = updated
    }

    func removeMetadata(for urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let updated = state.metadata.filter { !paths.contains($0.key) }
        if updated.count != state.metadata.count { state.metadata = updated }
    }

    func pruneMetadata(in folder: URL, keeping urls: Set<URL>) {
        let root = folder.standardizedFileURL
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let updated = state.metadata.filter {
            URL(fileURLWithPath: $0.key).deletingLastPathComponent() != root || paths.contains($0.key)
        }
        if updated.count != state.metadata.count { state.metadata = updated }
    }
}

struct IndexedScreenshot: Codable, Sendable {
    var modifiedAt: Date
    var byteCount: Int
    var text: String
}

actor LibrarySearchIndex {
    private var entries: [String: IndexedScreenshot] = [:]
    private let parser = ScreenshotParserService()
    private let url: URL

    init(url: URL = ProjectStore.directory.deletingLastPathComponent().appendingPathComponent("SearchIndex.json")) {
        self.url = url
        entries = (try? JSONDecoder().decode([String: IndexedScreenshot].self, from: Data(contentsOf: url))) ?? [:]
    }

    func text(for file: URL, modifiedAt: Date) async throws -> String {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let key = file.standardizedFileURL.path
        if let cached = entries[key], cached.modifiedAt == modifiedAt, cached.byteCount == size { return cached.text }
        try Task.checkCancellation()
        // Bound OCR memory for large screenshots; indexed text is local only.
        guard let image = ImageIOService.thumbnail(at: file, maxPixelSize: 4096) else { throw ExportError.invalidImage }
        let result = try await parser.parse(image)
        try Task.checkCancellation()
        entries[key] = IndexedScreenshot(modifiedAt: modifiedAt, byteCount: size, text: result.text)
        return result.text
    }

    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    func remove(_ urls: [URL]) {
        for url in urls { entries.removeValue(forKey: url.standardizedFileURL.path) }
    }

    func prune(in folder: URL, keeping urls: Set<URL>) throws {
        let root = folder.standardizedFileURL
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        entries = entries.filter {
            URL(fileURLWithPath: $0.key).deletingLastPathComponent() != root || paths.contains($0.key)
        }
        try save()
    }
}
