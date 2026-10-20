import AppKit

enum StitchError: LocalizedError {
    case incompatibleFrames, tooLarge
    var errorDescription: String? {
        switch self {
        case .incompatibleFrames: String(localized: "Scrolling captures must have the same width and a valid overlap.")
        case .tooLarge: String(localized: "The scrolling image is too large. Finish this capture and start another.")
        }
    }
}

enum ScrollingStitcher {
    static func trim(_ image: CGImage, top: Int, bottom: Int) throws -> CGImage {
        guard top >= 0, bottom >= 0, top < image.height, bottom < image.height,
              top + bottom < image.height - 31,
              let cropped = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top - bottom)) else {
            throw StitchError.incompatibleFrames
        }
        return cropped
    }

    static func seam(previous: CGImage, next: CGImage, overlap: Int) throws -> CGImage {
        guard overlap >= 0, overlap < next.height,
              let before = previous.cropping(to: CGRect(x: 0, y: max(0, previous.height - 80), width: previous.width, height: min(80, previous.height))),
              let after = next.cropping(to: CGRect(x: 0, y: overlap, width: next.width, height: min(80, next.height - overlap))) else {
            throw StitchError.incompatibleFrames
        }
        return try stitch([before, after], overlaps: [0])
    }

    /// Estimate overlap only when there is enough detail and a clear match.
    /// Ambiguous/animated content remains available for manual alignment.
    static func estimateOverlap(previous: CGImage, next: CGImage) -> Int? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let width = 64, height = min(512, previous.height)
        guard height >= 32, let a = samples(previous, width: width, height: height),
              let b = samples(next, width: width, height: height) else { return nil }
        var scores: [(Int, Double)] = []
        for overlap in max(8, height / 8)...(height - 4) {
            var difference = 0.0, sum = 0.0, square = 0.0, count = 0.0
            for y in stride(from: 0, to: overlap, by: max(1, overlap / 48)) {
                for x in stride(from: 4, to: width - 4, by: 3) {
                    let left = Double(a[(height - overlap + y) * width + x])
                    let right = Double(b[y * width + x])
                    difference += abs(left - right)
                    sum += left; square += left * left; count += 1
                }
            }
            guard count > 0, square / count - pow(sum / count, 2) > 80 else { continue }
            scores.append((overlap, difference / count))
        }
        guard let best = scores.min(by: { $0.1 < $1.1 }), best.1 < 14 else { return nil }
        let competitor = scores.filter { abs($0.0 - best.0) > 5 }.map(\.1).min() ?? 255
        guard competitor > best.1 * 1.3 + 2 else { return nil }
        return Int((Double(best.0) * Double(previous.height) / Double(height)).rounded())
    }

    private static func samples(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? pixels : nil
    }

    static func stitch(_ frames: [CGImage], overlaps: [Int]) throws -> CGImage {
        guard let first = frames.first, overlaps.count == frames.count - 1 else { throw StitchError.incompatibleFrames }
        var height = first.height
        for (index, image) in frames.dropFirst().enumerated() {
            guard image.width == first.width, overlaps[index] >= 0,
                  overlaps[index] < min(image.height, frames[index].height) else { throw StitchError.incompatibleFrames }
            height += image.height - overlaps[index]
        }
        guard height <= 60_000, first.width * height <= 80_000_000 else { throw StitchError.tooLarge }
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.invalidImage
        }
        var top = height
        for (index, image) in frames.enumerated() {
            let overlap = index == 0 ? 0 : overlaps[index - 1]
            let portionHeight = image.height - overlap
            guard let portion = image.cropping(to: CGRect(x: 0, y: overlap, width: image.width, height: portionHeight)) else {
                throw ExportError.invalidImage
            }
            top -= portionHeight
            context.draw(portion, in: CGRect(x: 0, y: top, width: image.width, height: portionHeight))
        }
        guard let image = context.makeImage() else { throw ExportError.invalidImage }
        return image
    }
}
