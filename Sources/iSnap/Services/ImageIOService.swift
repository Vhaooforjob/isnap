import AppKit
import Foundation
import ImageIO

enum ImageIOService {
    static func fullImage(at url: URL, maxPixels: Int = 80_000_000) throws -> CGImage {
        guard let size = pixelSize(at: url), size.width > 0, size.height > 0,
              size.width * size.height <= CGFloat(maxPixels),
              let image = thumbnail(at: url, maxPixelSize: Int(max(size.width, size.height))) else { throw ExportError.invalidImage }
        return image
    }

    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, ImageBox>()

    private init() {
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for item: LibraryItem, maxPixelSize: Int) -> CGImage? {
        let key = "\(item.url.path)|\(item.fileIdentity ?? "")|\(item.byteCount)|\(item.modifiedAt.timeIntervalSinceReferenceDate)|\(maxPixelSize)" as NSString
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: key) { return cached.image }
        guard let image = ImageIOService.thumbnail(at: item.url, maxPixelSize: maxPixelSize) else { return nil }
        guard !Task.isCancelled else { return nil }
        cache.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
