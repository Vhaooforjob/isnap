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
            guard let image = NSImage(contentsOf: input) else { throw ExportError.invalidImage }
            let rendered = try ExportRenderer.render(RenderRequest(image: image, annotations: [], canvas: options.canvas, includeBackground: true))
            guard var cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
            if options.maxDimension > 0, max(cg.width, cg.height) > options.maxDimension {
                let scale = CGFloat(options.maxDimension) / CGFloat(max(cg.width, cg.height))
                let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.invalidImage }
                context.interpolationQuality = .high
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let resized = context.makeImage() else { throw ExportError.invalidImage }
                cg = resized
            }
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
