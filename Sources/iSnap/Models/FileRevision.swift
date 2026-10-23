import Foundation

/// Metadata fingerprint invalidates caches on ordinary edits and atomic file replacement.
struct FileRevision: Equatable {
    let size: UInt64
    let modified: Date
    let identity: String?
    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return Self(size: size.uint64Value, modified: modified, identity: FileIdentity.read(url))
    }
}
