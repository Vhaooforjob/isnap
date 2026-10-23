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

struct LibraryMetadata: Codable, Equatable {
    var favorite = false
    var tags: [String] = []
    var collectionIDs: Set<UUID>?
    var recordID: UUID?
    var fileIdentity: String?
}

struct WorkspaceState: Codable {
    var presets: [CanvasPreset] = []
    var metadata: [String: LibraryMetadata] = [:]
    var captureDelay = 0
    var showsCursor = false
    var workflows: [CaptureWorkflow]?
    var collections: [LibraryCollection]?
    var savedFilters: [SavedLibraryFilter]?
    var redactionRules: [RedactionRule]?
    var detachedMetadata: [String: LibraryMetadata]?
    var annotationPresets: [AnnotationPreset]?
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

    /// Reconcile by filesystem identity before pruning paths. Copies get their own
    /// identity; removed records remain available for explicit relinking/backup.
    func reconcileLibrary(_ items: [LibraryItem], in folder: URL) {
        var updated = state
        var detached = updated.detachedMetadata ?? [:]
        let paths = Set(items.map { $0.url.standardizedFileURL.path })
        for (path, value) in state.metadata where URL(fileURLWithPath: path).deletingLastPathComponent() == folder.standardizedFileURL && !paths.contains(path) {
            detached[path] = value; updated.metadata.removeValue(forKey: path)
        }
        var byIdentity: [String: (String, LibraryMetadata)] = [:]
        for (path, value) in detached.merging(state.metadata, uniquingKeysWith: { _, live in live }) {
            if let identity = value.fileIdentity { byIdentity[identity] = (path, value) }
        }
        for item in items {
            let path = item.url.standardizedFileURL.path
            var value = updated.metadata[path]
            if let existing = value, let old = existing.fileIdentity, let current = item.fileIdentity, old != current {
                detached[path] = existing; value = nil
            }
            if value == nil, let identity = item.fileIdentity, let (oldPath, old) = byIdentity[identity] {
                value = old; detached.removeValue(forKey: oldPath)
                if oldPath != path && !paths.contains(oldPath) { updated.metadata.removeValue(forKey: oldPath) }
            }
            var record = value ?? LibraryMetadata()
            if record.recordID == nil { record.recordID = UUID() }
            record.fileIdentity = item.fileIdentity
            updated.metadata[path] = record
        }
        updated.detachedMetadata = detached
        if updated.metadata != state.metadata || detached != (state.detachedMetadata ?? [:]) { state = updated }
    }

    func relinkMetadata(from oldPath: String, to item: LibraryItem) {
        guard var record = state.detachedMetadata?[oldPath] else { return }
        var updated = state
        record.fileIdentity = item.fileIdentity
        // An explicit relink merges user organization rather than dropping destination tags.
        let current = metadata(for: item.url)
        record.tags = Array(Set(record.tags + current.tags)).sorted()
        record.favorite = record.favorite || current.favorite
        record.collectionIDs = (record.collectionIDs ?? []).union(current.collectionIDs ?? [])
        updated.metadata[item.url.standardizedFileURL.path] = record
        updated.detachedMetadata?.removeValue(forKey: oldPath)
        state = updated
    }

    func exportLibraryMetadata() throws -> Data {
        try JSONEncoder().encode(LibraryMetadataBackup(version: 1, metadata: state.metadata,
            detached: state.detachedMetadata ?? [:], collections: state.collections ?? [], filters: state.savedFilters ?? []))
    }

    func importLibraryMetadata(_ data: Data) throws {
        guard data.count <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let backup = try JSONDecoder().decode(LibraryMetadataBackup.self, from: data)
        guard backup.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        var updated = state
        // Keep imported paths detached until a scan or explicit relink proves identity.
        var detached = updated.detachedMetadata ?? [:]
        for (path, record) in backup.metadata.merging(backup.detached, uniquingKeysWith: { live, _ in live }) {
            detached[path] = record
        }
        var byRecord: [UUID: String] = [:], byFile: [String: String] = [:]
        for (path, value) in detached {
            if let id = value.recordID { byRecord[id] = path }
            if let id = value.fileIdentity { byFile[id] = path }
        }
        for (path, var current) in updated.metadata {
            if let key = current.recordID.flatMap({ byRecord[$0] }) ?? current.fileIdentity.flatMap({ byFile[$0] }),
               let value = detached[key] {
                let match = (key: key, value: value)
                current.tags = Array(Set(current.tags + match.value.tags)).sorted()
                current.favorite = current.favorite || match.value.favorite
                current.collectionIDs = (current.collectionIDs ?? []).union(match.value.collectionIDs ?? [])
                updated.metadata[path] = current
                detached.removeValue(forKey: match.key)
            }
        }
        updated.detachedMetadata = detached
        var collections = updated.collections ?? [], filters = updated.savedFilters ?? []
        for item in backup.collections where !collections.contains(where: { $0.id == item.id }) { collections.append(item) }
        for item in backup.filters where !filters.contains(where: { $0.id == item.id }) { filters.append(item) }
        updated.collections = collections; updated.savedFilters = filters
        state = updated
    }

    func addTag(_ tag: String, to urls: [URL]) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        var updated = state
        for url in urls {
            let key = url.standardizedFileURL.path
            var value = updated.metadata[key] ?? LibraryMetadata()
            if !value.tags.contains(tag) { value.tags.append(tag); value.tags.sort() }
            updated.metadata[key] = value
        }
        state = updated
    }

    func setCollection(_ id: UUID, for urls: [URL], included: Bool) {
        guard state.collections?.contains(where: { $0.id == id }) == true else { return }
        var updated = state
        for url in urls {
            let key = url.standardizedFileURL.path
            var value = updated.metadata[key] ?? LibraryMetadata()
            var ids = value.collectionIDs ?? []
            if included { ids.insert(id) } else { ids.remove(id) }
            value.collectionIDs = ids
            updated.metadata[key] = value
        }
        state = updated
    }

    func deleteCollection(_ id: UUID) {
        var updated = state
        updated.collections?.removeAll { $0.id == id }
        for key in Array(updated.metadata.keys) { updated.metadata[key]?.collectionIDs?.remove(id) }
        for key in Array(updated.detachedMetadata?.keys ?? Dictionary<String, LibraryMetadata>().keys) { updated.detachedMetadata?[key]?.collectionIDs?.remove(id) }
        // Filters tied to a deleted collection must not silently broaden their scope.
        updated.savedFilters?.removeAll { $0.collectionID == id }
        state = updated
    }

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
        var next = state; next.metadata = updated
        next.detachedMetadata = next.detachedMetadata?.filter { !paths.contains($0.key) }
        state = next
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
        let image = try ImageIOService.fullImage(at: file)
        let result = try await parser.parse(image, recognizeCodes: false)
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
