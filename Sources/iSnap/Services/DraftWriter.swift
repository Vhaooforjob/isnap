import AppKit

struct ProjectSnapshot {
    let image: CGImage
    let originalImage: CGImage?
    var project: EditorProject
}

/// All draft writes share a serial queue. Synchronous lifecycle saves invalidate
/// queued autosaves and wait for any active write before preserving the final state.
final class DraftWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.isnap.drafts", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var encodedImages: [(CGImage, Data)] = []

    private func nextGeneration() -> UInt64 {
        lock.withLock { generation &+= 1; return generation }
    }

    func enqueue(_ snapshot: ProjectSnapshot, to url: URL, completion: @escaping (Error?) -> Void) {
        let token = nextGeneration()
        queue.async { [self] in
            guard lock.withLock({ generation == token }) else { return }
            do {
                let project = try encode(snapshot)
                guard lock.withLock({ generation == token }) else { return }
                try ProjectStore.writeDraft(project, to: url)
                completion(nil)
            } catch {
                if lock.withLock({ generation == token }) { completion(error) }
            }
        }
    }

    func save(_ snapshot: ProjectSnapshot, to urls: [URL]) throws {
        _ = nextGeneration()
        try queue.sync {
            let project = try encode(snapshot)
            for url in urls { try ProjectStore.writeDraft(project, to: url) }
        }
    }

    func flush() { queue.sync {} }

    private func encode(_ snapshot: ProjectSnapshot) throws -> EditorProject {
        try autoreleasepool {
            var project = snapshot.project
            project.image = try png(snapshot.image)
            project.originalImage = try snapshot.originalImage.map(png)
            project.backgroundImage = try project.canvas.backgroundImageURL.map { try Data(contentsOf: $0) }
            return project
        }
    }

    private func png(_ image: CGImage) throws -> Data {
        if let cached = encodedImages.first(where: { $0.0 === image }) { return cached.1 }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        encodedImages.append((image, data))
        if encodedImages.count > 2 { encodedImages.removeFirst() }
        return data
    }
}
