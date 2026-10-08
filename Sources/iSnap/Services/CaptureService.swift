import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case windowUnavailable
    case imageCreationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Screen Recording access is unavailable. If iSnap is already enabled in System Settings, quit and reopen the app so macOS can apply the permission.")
        case .displayUnavailable: String(localized: "No capturable display is available.")
        case .windowUnavailable: String(localized: "The selected window is no longer available.")
        case .imageCreationFailed: String(localized: "iSnap could not create an image from the capture.")
        case .cancelled: String(localized: "Capture cancelled.")
        }
    }
}

actor CaptureService {
    private func preparePermission(prompt: Bool = true) {
        if !CGPreflightScreenCaptureAccess(), prompt {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func shareableContent(
        excludingDesktopWindows: Bool,
        onScreenWindowsOnly: Bool
    ) async throws -> SCShareableContent {
        preparePermission()
        do {
            // ScreenCaptureKit is the source of truth. CGPreflightScreenCaptureAccess
            // can remain false until the process restarts after permission is granted.
            return try await SCShareableContent.excludingDesktopWindows(
                excludingDesktopWindows,
                onScreenWindowsOnly: onScreenWindowsOnly
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            throw error
        }
    }

    func captureAllDisplays() async throws -> CaptureResult {
        let content = try await shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw CaptureError.displayUnavailable }

        let union = content.displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let scales = await MainActor.run { content.displays.map { Self.displayScale(for: $0.displayID) } }
        let scale = scales.max() ?? 1
        let width = max(1, Int(union.width * scale))
        let height = max(1, Int(union.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError.imageCreationFailed }

        for (display, displayScale) in zip(content.displays, scales) {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * displayScale)
            configuration.height = Int(CGFloat(display.height) * displayScale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let x = (display.frame.minX - union.minX) * scale
            let yFromTop = (display.frame.minY - union.minY) * scale
            let destination = CGRect(
                x: x,
                y: CGFloat(height) - yFromTop - display.frame.height * scale,
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
            context.draw(image, in: destination)
        }
        guard let image = context.makeImage() else { throw CaptureError.imageCreationFailed }
        return CaptureResult(
            image: NSImage(cgImage: image, size: CGSize(width: width, height: height)),
            sourceName: String(localized: "All Displays")
        )
    }

    func displays() async throws -> [SCDisplay] {
        return try await shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: true).displays
    }

    func capture(displayID: CGDirectDisplayID, region: CGRect? = nil) async throws -> CaptureResult {
        let content = try await shareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let scale = await MainActor.run { Self.displayScale(for: display.displayID) }
        let configuration = SCStreamConfiguration()
        if let region {
            configuration.sourceRect = region
            configuration.width = max(1, Int(region.width * scale))
            configuration.height = max(1, Int(region.height * scale))
        } else {
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
        }
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CaptureResult(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
            sourceName: region == nil ? String(localized: "Screen") : String(localized: "Region")
        )
    }

    func windows() async throws -> [CapturableWindow] {
        let content = try await shareableContent(excludingDesktopWindows: true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        let candidates = content.windows
            .filter { window in
                window.windowLayer == 0 && window.frame.width >= 80 && window.frame.height >= 60 &&
                window.owningApplication?.bundleIdentifier != ownBundleID &&
                !(window.title?.isEmpty ?? true)
            }
            .sorted { lhs, rhs in
                let leftApp = lhs.owningApplication?.applicationName ?? ""
                let rightApp = rhs.owningApplication?.applicationName ?? ""
                if leftApp == rightApp { return (lhs.title ?? "") < (rhs.title ?? "") }
                return leftApp < rightApp
            }
        return await candidates.asyncMap { window in
            let configuration = SCStreamConfiguration()
            let thumbnailWidth: CGFloat = 192
            let scale = min(1, thumbnailWidth / max(1, window.frame.width))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.captureResolution = .best
            configuration.ignoreShadowsSingleWindow = false
            let thumbnailCG = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            return CapturableWindow(
                    id: window.windowID,
                    title: window.title ?? String(localized: "Untitled Window"),
                    applicationName: window.owningApplication?.applicationName ?? String(localized: "Application"),
                    frame: window.frame,
                    thumbnail: thumbnailCG.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
                )
            }
    }

    func capture(windowID: CGWindowID) async throws -> CaptureResult {
        let content = try await shareableContent(excludingDesktopWindows: true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowUnavailable
        }
        let configuration = SCStreamConfiguration()
        let scale = await MainActor.run { Self.windowScale(for: window.frame) }
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CaptureResult(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
            sourceName: window.title ?? String(localized: "Window")
        )
    }

    /// ScreenCaptureKit frames use a top-left origin and AppKit frames a
    /// bottom-left one, so displays are matched by ID, never by frame.
    @MainActor
    static func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The scale of the display holding most of a window (top-left global frame).
    @MainActor
    static func windowScale(for frame: CGRect) -> CGFloat {
        guard let main = NSScreen.screens.first else { return 2 }
        let appKitFrame = CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let screen = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(appKitFrame).area < rhs.frame.intersection(appKitFrame).area
        }
        return screen?.backingScaleFactor ?? main.backingScaleFactor
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(try await transform(element)) }
        return values
    }

    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(await transform(element)) }
        return values
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen the pointer is on: where the user is working.
    static var underPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens.first
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
