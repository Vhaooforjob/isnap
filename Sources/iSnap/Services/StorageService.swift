import Foundation

/// The places iSnap keeps files, grouped the way Settings → Storage shows them.
enum StorageKind: String, CaseIterable, Identifiable, Sendable {
    /// Saved and archived screenshots: the user's files, never cleared as cache.
    case library
    /// Captures that only live on the Capture Line (clipboard screenshots,
    /// routed macOS screenshots, captures made with archiving off).
    case captureLine
    /// Network cache, Vision model cache, and files prepared for sharing.
    case cache
    /// Thumbnails published for the widget; rebuilt from the Library.
    case widget
    /// Custom background images.
    case backgrounds
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: String(localized: "Screenshot Library")
        case .captureLine: String(localized: "Capture Line")
        case .cache: String(localized: "Cache")
        case .widget: String(localized: "Widget Thumbnails")
        case .backgrounds: String(localized: "Custom Backgrounds")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.stack"
        case .captureLine: "rectangle.3.group"
        case .cache: "internaldrive"
        case .widget: "square.grid.2x2"
        case .backgrounds: "photo.artframe"
        case .settings: "gearshape"
        }
    }

    /// Cleared by Clear Cache: everything here is rebuilt on demand.
    var isCache: Bool { self == .cache || self == .widget }
}

struct StorageUsage: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let kind: StorageKind
        let bytes: Int64
        let locations: [URL]
        var id: StorageKind { kind }
    }

    let entries: [Entry]
    let measuredAt: Date

    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var cacheBytes: Int64 { entries.filter(\.kind.isCache).reduce(0) { $0 + $1.bytes } }

    func bytes(for kind: StorageKind) -> Int64 {
        entries.first { $0.kind == kind }?.bytes ?? 0
    }
}

/// Measures and clears iSnap's files. Measuring walks directories, so it
/// runs off the main thread.
enum StorageService {
    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iSnap", isDirectory: true)

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.isnap.app", isDirectory: true)
    }

    /// Rendered images handed to share services and other apps.
    static var shareFolder: URL { cacheFolder.appendingPathComponent("Share", isDirectory: true) }

    /// URLCache keeps its database open; it is emptied through the API
    /// instead of deleting these files under it.
    private static let liveCacheFiles: Set<String> = ["Cache.db", "Cache.db-shm", "Cache.db-wal"]

    static func locations(libraryFolder: URL, lineFolder: URL) -> [StorageKind: [URL]] {
        [
            .library: [libraryFolder],
            .captureLine: [lineFolder],
            .cache: [cacheFolder],
            .widget: WidgetSnapshotService.widgetDirectories(),
            .backgrounds: [appSupport.appendingPathComponent("Backgrounds", isDirectory: true)],
            .settings: [appSupport.appendingPathComponent("settings.json")]
        ]
    }

    static func measure(_ locations: [StorageKind: [URL]]) -> StorageUsage {
        let entries = StorageKind.allCases.map { kind in
            let urls = locations[kind] ?? []
            return StorageUsage.Entry(kind: kind, bytes: urls.reduce(0) { $0 + size(of: $1) }, locations: urls)
        }
        return StorageUsage(entries: entries, measuredAt: Date())
    }

    /// Allocated size on disk of a file or a folder and everything in it.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        func fileSize(_ values: URLResourceValues?) -> Int64 {
            Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileSize(try? url.resourceValues(forKeys: keys)) }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { total += fileSize(values) }
        }
        return total
    }

    /// Removes everything that is rebuilt on demand: the network cache, the
    /// Vision model cache, prepared share files, and widget thumbnails.
    /// Screenshots, backgrounds, and settings are kept.
    static func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        removeContents(of: cacheFolder, keeping: liveCacheFiles)
        for folder in WidgetSnapshotService.widgetDirectories() {
            removeContents(of: folder, keeping: [])
        }
    }

    private static func removeContents(of folder: URL, keeping kept: Set<String>) {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where !kept.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
