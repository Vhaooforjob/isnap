import AppKit

enum ScrollDirection: String, CaseIterable, Identifiable {
    case down, up, right, left
    var id: String { rawValue }
    var title: String { switch self {
    case .down: String(localized: "Down")
    case .up: String(localized: "Up")
    case .right: String(localized: "Right")
    case .left: String(localized: "Left")
    } }
    var inverse: Self { self == .right ? .left : self == .left ? .right : self }
    func orient(_ image: CGImage) throws -> CGImage {
        if self == .down { return image }
        let horizontal = self == .right || self == .left
        let w = image.width, h = image.height, outW = horizontal ? h : w, outH = horizontal ? w : h
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let input = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info),
              let output = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4, space: space, bitmapInfo: info),
              let src = input.data?.assumingMemoryBound(to: UInt32.self), let dst = output.data?.assumingMemoryBound(to: UInt32.self) else { throw ExportError.invalidImage }
        input.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let target: (Int, Int)
                switch self { case .up: target = (w - 1 - x, h - 1 - y)
                case .right: target = (h - 1 - y, x)
                case .left: target = (y, w - 1 - x)
                case .down: target = (x, y) }
                dst[target.1 * outW + target.0] = src[y * w + x]
            }
        }
        guard let result = output.makeImage() else { throw ExportError.invalidImage }; return result
    }
}

struct ScrollSourceGuard {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let windowID: CGWindowID?
    let windowBounds: CGRect?
    let point: CGPoint

    init(selection: ScreenSelection) {
        displayID = selection.displayID; displayBounds = CGDisplayBounds(selection.displayID)
        pixelWidth = CGDisplayPixelsWide(selection.displayID); pixelHeight = CGDisplayPixelsHigh(selection.displayID)
        point = CGPoint(x: displayBounds.minX + selection.rect.midX, y: displayBounds.minY + selection.rect.midY)
        let capturePoint = point
        let source = Self.windows().first { Self.bounds($0)?.contains(capturePoint) == true }
        windowID = (source?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        windowBounds = source.flatMap(Self.bounds)
    }
    func validate() throws {
        guard CGDisplayBounds(displayID) == displayBounds, CGDisplayPixelsWide(displayID) == pixelWidth,
              CGDisplayPixelsHigh(displayID) == pixelHeight else { throw SourceChanged() }
        if let windowID {
            let windows = Self.windows()
            guard let source = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
                  Self.bounds(source) == windowBounds,
                  let foreground = windows.first(where: { Self.bounds($0)?.contains(point) == true }),
                  (foreground[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID else { throw SourceChanged() }
        }
    }
    private static func windows() -> [[String: Any]] {
        ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }
    private static func bounds(_ info: [String: Any]) -> CGRect? {
        guard let value = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: value as CFDictionary)
    }
    struct SourceChanged: LocalizedError {
        var errorDescription: String? { String(localized: "Capture paused because the source window or display moved, resized, disappeared or was covered. Restore the source before continuing.") }
    }
}
