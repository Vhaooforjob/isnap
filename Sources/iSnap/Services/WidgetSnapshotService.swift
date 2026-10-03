import AppKit
import Foundation
import WidgetKit

struct WidgetSnapshotItem: Codable {
    let name: String
    let thumbnailName: String
    let modifiedAt: Date
    let width: Int
    let height: Int
}

struct WidgetSnapshot: Codable {
    let updatedAt: Date
    let totalCount: Int
    let items: [WidgetSnapshotItem]
}

enum WidgetSnapshotService {
    static let appGroupIdentifier = "group.dev.isnap.app"
    static let widgetKind = "iSnapRecentWidget"

    static func publish(_ libraryItems: [LibraryItem]) {
        var didPublish = false
        for directory in widgetDirectories() {
            do {
                try publish(libraryItems, to: directory)
                didPublish = true
            } catch {
                continue
            }
        }
        if didPublish {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }

    private static func publish(_ libraryItems: [LibraryItem], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let recentItems = Array(libraryItems.prefix(3))
        var snapshotItems: [WidgetSnapshotItem] = []
        for (index, item) in recentItems.enumerated() {
            let thumbnailName = "recent-\(index).jpg"
            let thumbnailURL = directory.appendingPathComponent(thumbnailName)
            if let data = thumbnailData(from: item.url) {
                try data.write(to: thumbnailURL, options: .atomic)
                snapshotItems.append(WidgetSnapshotItem(
                    name: item.name,
                    thumbnailName: thumbnailName,
                    modifiedAt: item.modifiedAt,
                    width: Int(item.dimensions.width),
                    height: Int(item.dimensions.height)
                ))
            }
        }

        for index in recentItems.count..<3 {
            let staleURL = directory.appendingPathComponent("recent-\(index).jpg")
            try? FileManager.default.removeItem(at: staleURL)
        }

        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            totalCount: libraryItems.count,
            items: snapshotItems
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    private static func widgetDirectories() -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []
        if let groupDirectory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            directories.append(groupDirectory.appendingPathComponent("Widget", isDirectory: true))
        }
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let fallback = applicationSupport.appendingPathComponent("iSnap/Widget", isDirectory: true)
            if !directories.contains(fallback) { directories.append(fallback) }
        }
        return directories
    }

    private static func thumbnailData(from url: URL) -> Data? {
        guard let source = NSImage(contentsOf: url) else { return nil }
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let maximumPixel: CGFloat = 640
        let scale = min(1, maximumPixel / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: CGRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.76])
    }
}
