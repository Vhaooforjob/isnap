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
    var assets: [String: String]?
}

enum ProjectStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iSnap/Drafts", isDirectory: true)
    static let latestURL = directory.appendingPathComponent("Latest.isnap")
    static let previousURL = directory.appendingPathComponent("Previous.isnap")
    static let draftLock = NSRecursiveLock()

    static func write(_ project: EditorProject, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> EditorProject {
        var project = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: url))
        guard project.version == 1 else { throw ProjectError.unsupportedVersion }
        if let assets = project.assets {
            func load(_ key: String) throws -> Data? {
                guard let hash = assets[key] else { return nil }
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw ExportError.invalidImage }
                let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(".Assets/\(hash)"))
                guard ProjectAsset.digest(data) == hash else { throw ExportError.invalidImage }
                return data
            }
            project.image = try load("source") ?? project.image
            project.originalImage = try load("original") ?? project.originalImage
            project.backgroundImage = try load("background") ?? project.backgroundImage
            for index in project.annotations.indices {
                project.annotations[index].imageData = try load("layer-\(project.annotations[index].id)") ?? project.annotations[index].imageData
            }
            for index in project.originalAnnotations.indices {
                project.originalAnnotations[index].imageData = try load("original-layer-\(project.originalAnnotations[index].id)") ?? project.originalAnnotations[index].imageData
            }
            if let watermark = try load("watermark") { project.canvas.watermark?.imageData = watermark }
            project.assets = nil
        }
        return project
    }

    static func writeDraft(_ project: EditorProject, to url: URL) throws {
        try draftLock.withLock {
            var manifest = project
            var assets: [String: String] = [:]
            let folder = url.deletingLastPathComponent().appendingPathComponent(".Assets")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func store(_ data: Data?, key: String) throws {
                guard let data else { return }
                let hash = ProjectAsset.digest(data)
                let target = folder.appendingPathComponent(hash)
                if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
                assets[key] = hash
            }
            try store(project.image, key: "source"); manifest.image = Data()
            try store(project.originalImage, key: "original"); manifest.originalImage = nil
            try store(project.backgroundImage, key: "background"); manifest.backgroundImage = nil
            for index in manifest.annotations.indices {
                try store(manifest.annotations[index].imageData, key: "layer-\(manifest.annotations[index].id)")
                manifest.annotations[index].imageData = nil
            }
            for index in manifest.originalAnnotations.indices {
                try store(manifest.originalAnnotations[index].imageData, key: "original-layer-\(manifest.originalAnnotations[index].id)")
                manifest.originalAnnotations[index].imageData = nil
            }
            try store(manifest.canvas.watermark?.imageData, key: "watermark"); manifest.canvas.watermark?.imageData = nil
            manifest.assets = assets
            if url.lastPathComponent == "Latest.isnap", (try? read(url)) != nil {
                try Data(contentsOf: url).write(to: url.deletingLastPathComponent().appendingPathComponent("Previous.isnap"), options: .atomic)
            }
            try write(manifest, to: url)
        }
    }

    static func recover(in directory: URL = directory) throws -> EditorProject {
        func valid(_ name: String) throws -> EditorProject {
            let project = try read(directory.appendingPathComponent(name))
            guard let source = CGImageSourceCreateWithData(project.image as CFData, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw ExportError.invalidImage }
            return project
        }
        do { return try valid("Latest.isnap") }
        catch { return try valid("Previous.isnap") }
    }

    /// Under the same lock as writes, remove only assets unreferenced by every manifest.
    /// A damaged manifest prevents collection, preserving possible recovery data.
    static func collectAssets(in directory: URL) throws {
        try draftLock.withLock {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var used: Set<String> = []
            for file in files where file.pathExtension == "isnap" {
                let project = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: file))
                used.formUnion(project.assets?.values.map { $0 } ?? [])
            }
            let folder = directory.appendingPathComponent(".Assets")
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                where !used.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
        }
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
        return urls.filter { $0.pathExtension == "isnap" && $0 != latestURL && $0 != previousURL }.sorted {
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
