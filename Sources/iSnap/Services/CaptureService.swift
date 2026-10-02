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
        case .permissionDenied: "Screen Recording access is unavailable. If iSnap is already enabled in System Settings, quit and reopen the app so macOS can apply the permission."
        case .displayUnavailable: "No capturable display is available."
        case .windowUnavailable: "The selected window is no longer available."
        case .imageCreationFailed: "iSnap could not create an image from the capture."
        case .cancelled: "Capture cancelled."
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

        let captures = try await content.displays.asyncMap { display -> (SCDisplay, CGImage) in
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * displayScale(for: display.frame))
            configuration.height = Int(CGFloat(display.height) * displayScale(for: display.frame))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (display, image)
        }

        let union = captures.map { $0.0.frame }.reduce(CGRect.null) { $0.union($1) }
        let scale = captures.map { displayScale(for: $0.0.frame) }.max() ?? 1
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

        for (display, image) in captures {
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
            sourceName: "All Displays"
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
        let scale = displayScale(for: display.frame)
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
            sourceName: region == nil ? "Display" : "Region"
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
            let thumbnailWidth: CGFloat = 320
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
                    title: window.title ?? "Untitled Window",
                    applicationName: window.owningApplication?.applicationName ?? "Application",
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CaptureResult(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
            sourceName: window.title ?? "Window"
        )
    }

    private func displayScale(for frame: CGRect) -> CGFloat {
        NSScreen.screens.first { screen in
            abs(screen.frame.minX - frame.minX) < 2 && abs(screen.frame.minY - frame.minY) < 2
        }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
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
