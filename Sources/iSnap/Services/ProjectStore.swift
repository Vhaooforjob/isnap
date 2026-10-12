import AppKit
import Foundation

struct EditorProject: Codable {
    var version = 1
    var sourceName: String
    var image: Data
    var originalImage: Data?
    var annotations: [Annotation]
    var originalAnnotations: [Annotation]
    var canvas: CanvasConfiguration
    var backgroundImage: Data?
    var cropRect: CGRect?
    var lastAppliedCrop: CGRect?
    var isCropApplied: Bool
}

enum ProjectStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iSnap/Drafts", isDirectory: true)
    static let latestURL = directory.appendingPathComponent("Latest.isnap")

    static func write(_ project: EditorProject, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> EditorProject {
        let project = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: url))
        guard project.version == 1 else { throw ProjectError.unsupportedVersion }
        return project
    }

    static func png(_ image: NSImage) throws -> Data {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    static var drafts: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "isnap" && $0 != latestURL }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
}

enum ProjectError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? { String(localized: "This project was created by an unsupported version of iSnap.") }
}
