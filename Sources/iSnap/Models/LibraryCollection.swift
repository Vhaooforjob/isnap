import Foundation

struct LibraryCollection: Codable, Identifiable {
    var id = UUID()
    var name: String
}

struct SavedLibraryFilter: Codable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var favoritesOnly: Bool
    var days: Int
    var collectionID: UUID?
    var sort: String
}

struct LibraryMetadataBackup: Codable {
    let version: Int
    let metadata: [String: LibraryMetadata]
    let detached: [String: LibraryMetadata]
    let collections: [LibraryCollection]
    let filters: [SavedLibraryFilter]
}

enum FileIdentity {
    static func read(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let birth = attributes[.creationDate] as? Date else { return nil }
        return "\(device):\(inode):\(birth.timeIntervalSinceReferenceDate)"
    }
}

struct AnnotationPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var style: AnnotationStyle
}
