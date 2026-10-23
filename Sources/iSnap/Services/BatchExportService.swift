import AppKit

struct BatchExportOptions {
    var canvas: CanvasConfiguration
    var format: ExportFormat = .png
    var quality = 0.95
    var maxDimension = 0
    var prefix = "iSnap"
}

actor BatchExportService {
    func export(_ input: URL, to folder: URL, index: Int, options: BatchExportOptions) throws -> URL {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard (0...16_384).contains(options.maxDimension),
                  let size = ImageIOService.pixelSize(at: input), size.width > 0, size.height > 0,
                  size.width * size.height <= 80_000_000 else { throw ExportError.invalidImage }
            let decodeLimit = options.maxDimension > 0 ? options.maxDimension : Int(max(size.width, size.height))
            guard let source = ImageIOService.thumbnail(at: input, maxPixelSize: decodeLimit) else { throw ExportError.invalidImage }
            let image = NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height))
            let rendered = try ExportRenderer.render(RenderRequest(image: image, annotations: [], canvas: options.canvas,
                includeBackground: true, sourcePixelSize: size), maxPixelDimension: options.maxDimension > 0 ? options.maxDimension : nil)
            guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard let data = bitmap.representation(using: options.format == .png ? .png : .jpeg,
                properties: options.format == .jpeg ? [.compressionFactor: options.quality.clamped(to: 0...1)] : [:]) else { throw ExportError.encodingFailed }
            let prefix = options.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            let base = prefix.isEmpty ? input.deletingPathExtension().lastPathComponent : String(format: "%@-%03d", prefix, index)
            var output = folder.appendingPathComponent(base).appendingPathExtension(options.format.fileExtension)
            var suffix = 2
            while FileManager.default.fileExists(atPath: output.path) {
                output = folder.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension(options.format.fileExtension)
                suffix += 1
            }
            try Task.checkCancellation()
            // Preserve originals even when exporting back into the source folder.
            try data.write(to: output, options: .withoutOverwriting)
            return output
        }
    }
}
