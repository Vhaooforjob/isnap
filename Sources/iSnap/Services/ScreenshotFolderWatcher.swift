import AppKit
import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones, so
/// captures taken with ⇧⌘3/4/5 (or any other tool) hang on the Capture Line
/// next to iSnap's own. Adapted from Tendedero (MIT).
@MainActor
final class ScreenshotFolderWatcher {
    let folder: URL
    /// On the Desktop only real screenshots count, tagged by macOS with an
    /// extended attribute. In a dedicated folder any image counts.
    private let onlyTaggedScreenshots: Bool
    private let launchDate = Date()
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

    init(folder: URL? = nil, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.folder = folder ?? Self.systemScreenshotFolder()
        self.onNew = onNew
        self.onChange = onChange
        onlyTaggedScreenshots = self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
    }

    /// The folder macOS currently saves screenshots to, read fresh because
    /// screenshot routing changes it at runtime.
    static func systemScreenshotFolder() -> URL {
        let domain = SystemScreenshotRouting.domain
        CFPreferencesAppSynchronize(domain)
        // macOS 27 reads "location-screenshot"; earlier versions read "location".
        let raw = (CFPreferencesCopyAppValue(SystemScreenshotRouting.screenshotLocationKey, domain) as? String)
            ?? (CFPreferencesCopyAppValue(SystemScreenshotRouting.locationKey, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return desktop
    }

    func start() {
        let files = listing()
        // Anything created after launch counts as new, even if it landed
        // before the watcher was ready.
        known = Set(files.filter { creationDate($0) < launchDate }.map(\.path))
        for url in files where !known.contains(url.path) && isCandidate(url) { onNew(url) }
        known = Set(files.map(\.path))

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pendingScan?.cancel()
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        // macOS writes a hidden temporary file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        let files = listing()
        for url in files where !known.contains(url.path) && isCandidate(url) { onNew(url) }
        known = Set(files.map(\.path))
        onChange()
    }

    private func listing() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? Self.isScreenCapture(url) : true
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }

    /// Where on screen a macOS screenshot was taken, in AppKit screen
    /// coordinates. macOS stores it on the file in global points with the
    /// origin at the top left of the main display.
    static func captureRect(of url: URL) -> CGRect? {
        let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let data: Data? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? buffer : nil
        }
        guard let data,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
              values.count == 4 else { return nil }
        return appKitRect(fromTopLeftGlobal: CGRect(
            x: CGFloat(truncating: values[0]),
            y: CGFloat(truncating: values[1]),
            width: CGFloat(truncating: values[2]),
            height: CGFloat(truncating: values[3])
        ))
    }

    /// Converts a global rectangle with a top-left origin (CoreGraphics and
    /// ScreenCaptureKit window frames) to AppKit's bottom-left screen space.
    static func appKitRect(fromTopLeftGlobal rect: CGRect) -> CGRect? {
        guard rect.width > 2, rect.height > 2, let main = NSScreen.screens.first else { return nil }
        return CGRect(x: rect.minX, y: main.frame.maxY - rect.minY - rect.height, width: rect.width, height: rect.height)
    }
}

/// Optional takeover of where macOS saves screenshots. It changes the same
/// two settings found under Options in ⇧⌘5: the floating thumbnail is turned
/// off, so the file is written at once, and the save location becomes
/// iSnap's line folder, so the Desktop only gets what you keep.
///
/// Previous values are saved first and put back when the option is turned
/// off or iSnap quits, so macOS is never left pointing at a folder nobody
/// watches.
enum SystemScreenshotRouting {
    static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location"; macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    static let locationKey = "location" as CFString
    static let screenshotLocationKey = "location-screenshot" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    private static let savedKey = "captureLine.savedScreencaptureSettings"

    static func isApplied(to folder: URL) -> Bool {
        CFPreferencesAppSynchronize(domain)
        guard let current = CFPreferencesCopyAppValue(locationKey, domain) as? String else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    static func apply(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never save our own values as the previous ones, for example after
        // a crash left them applied.
        if !isApplied(to: folder) {
            let saved: [String: Any?] = [
                "location": CFPreferencesCopyAppValue(locationKey, domain) as? String,
                "locationScreenshot": CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String,
                "thumbnail": CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool
            ]
            UserDefaults.standard.set(saved.compactMapValues { $0 }, forKey: savedKey)
        }
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(thumbnailKey, false)
    }

    static func restore(from folder: URL) {
        guard isApplied(to: folder) else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Writes through cfprefsd so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
