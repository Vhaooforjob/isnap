import AppKit
import Foundation

actor LibraryService {
    func items(in folder: URL) throws -> [LibraryItem] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let image = NSImage(contentsOf: url) else { return nil }
            let dimensions = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
            return LibraryItem(url: url, modifiedAt: values.contentModificationDate ?? .distantPast, dimensions: dimensions)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func delete(_ item: LibraryItem, rootFolder: URL) throws {
        let root = rootFolder.standardizedFileURL.resolvingSymlinksInPath()
        let target = item.url.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent() == root else { return }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}

