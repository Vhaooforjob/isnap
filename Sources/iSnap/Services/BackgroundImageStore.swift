import AppKit
import Foundation

enum BackgroundImageStore {
    static func importImage(from source: URL) throws -> URL {
        guard let image = NSImage(contentsOf: source),
              let sourceCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.invalidImage
        }
        let maxDimension: CGFloat = 2048
        let sourceSize = CGSize(width: sourceCG.width, height: sourceCG.height)
        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let size = CGSize(width: floor(sourceSize.width * scale), height: floor(sourceSize.height * scale))
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.invalidImage }
        context.interpolationQuality = .high
        context.draw(sourceCG, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw ExportError.invalidImage }
        let bitmap = NSBitmapImageRep(cgImage: result)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ExportError.encodingFailed
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSnap/Backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func remove(_ url: URL) throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSnap/Backgrounds", isDirectory: true)
            .standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == root else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
