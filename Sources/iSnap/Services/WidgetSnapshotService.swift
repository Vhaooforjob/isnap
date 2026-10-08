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
                didPublish = try publish(libraryItems, to: directory) || didPublish
            } catch {
                continue
            }
        }
        if didPublish {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }

    private static func publish(_ libraryItems: [LibraryItem], to directory: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let recentItems = Array(libraryItems.prefix(3))
        let snapshotURL = directory.appendingPathComponent("snapshot.json")
        if isCurrent(snapshotURL: snapshotURL, directory: directory, libraryItems: libraryItems, recentItems: recentItems) {
            return false
        }
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
        try data.write(to: snapshotURL, options: .atomic)
        return true
    }

    private static func isCurrent(
        snapshotURL: URL,
        directory: URL,
        libraryItems: [LibraryItem],
        recentItems: [LibraryItem]
    ) -> Bool {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.totalCount == libraryItems.count,
              snapshot.items.count == recentItems.count else { return false }
        return zip(snapshot.items, recentItems).allSatisfy { snapshotItem, libraryItem in
            snapshotItem.name == libraryItem.name &&
            snapshotItem.modifiedAt == libraryItem.modifiedAt &&
            snapshotItem.width == Int(libraryItem.dimensions.width) &&
            snapshotItem.height == Int(libraryItem.dimensions.height) &&
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(snapshotItem.thumbnailName).path
            )
        }
    }

    static func widgetDirectories() -> [URL] {
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
        guard let thumbnail = ImageIOService.thumbnail(at: url, maxPixelSize: 640) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.76])
    }
}
