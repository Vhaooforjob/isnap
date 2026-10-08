import AppKit
import UniformTypeIdentifiers

/// Builds the Share menu used on Capture Line cards, in the editor, and in
/// the Library: system services (AirDrop, Messages, Mail, and every share
/// extension), Open With any app, copy variants, and cloud upload links.
@MainActor
enum ShareService {
    struct UploadTarget {
        let title: String
        let isAvailable: Bool
        let upload: () -> Void
    }

    static func menu(for url: URL, uploads: [UploadTarget]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Direct services first: the ones people reach for most.
        for name in [NSSharingService.Name.sendViaAirDrop, .composeMessage, .composeEmail] {
            guard let service = NSSharingService(named: name), service.canPerform(withItems: [url]) else { continue }
            let item = CaptureLineMenuItem(verbatim: service.menuItemTitle) { perform(service, with: url) }
            item.image = service.image
            menu.addItem(item)
        }
        // Every other share extension (Notes, Photos, Freeform, …) and "Edit Extensions…".
        let more = NSSharingServicePicker(items: [url]).standardShareMenuItem
        more.title = String(localized: "More Sharing Options")
        menu.addItem(more)

        menu.addItem(.separator())
        menu.addItem(openWithItem(for: url))

        menu.addItem(.separator())
        menu.addItem(CaptureLineMenuItem("Copy Image") { copyImage(at: url) })
        menu.addItem(CaptureLineMenuItem("Copy File") { copyFile(at: url) })
        menu.addItem(CaptureLineMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        })

        if !uploads.isEmpty {
            menu.addItem(.separator())
            let uploadItem = NSMenuItem(title: String(localized: "Upload and Copy Link"), action: nil, keyEquivalent: "")
            uploadItem.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for target in uploads {
                let item = CaptureLineMenuItem(verbatim: target.title, handler: target.upload)
                item.isEnabled = target.isAvailable
                submenu.addItem(item)
            }
            uploadItem.submenu = submenu
            menu.addItem(uploadItem)
        }

        menu.addItem(.separator())
        menu.addItem(CaptureLineMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        return menu
    }

    /// Pops the menu at the pointer, for SwiftUI buttons that have no NSView to anchor to.
    static func popUpAtPointer(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Services

    private static func perform(_ service: NSSharingService, with url: URL) {
        // The Capture Line never takes focus; the share sheet needs it.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: Open With

    private static func openWithItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        let submenu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL }
        if let defaultApp, let index = apps.firstIndex(of: defaultApp) {
            apps.remove(at: index)
            apps.insert(defaultApp, at: 0)
        }
        var seenNames = Set<String>()
        for app in apps {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            // The same app installed twice (for example in Xcode's folder) shows once.
            guard seenNames.insert(name).inserted else { continue }
            let title = app == defaultApp ? String(localized: "\(name) (default)") : name
            let appItem = CaptureLineMenuItem(verbatim: title) { open(url, with: app) }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            submenu.addItem(appItem)
            if app == defaultApp && apps.count > 1 { submenu.addItem(.separator()) }
        }
        submenu.addItem(.separator())
        submenu.addItem(CaptureLineMenuItem("Other…") { chooseApp(for: url) })
        item.submenu = submenu
        return item
    }

    private static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func chooseApp(for url: URL) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an App")
        panel.prompt = String(localized: "Open")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(url, with: app)
    }

    // MARK: Copy

    private static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// The file itself, so pasting into Finder, chat apps, or Mail attaches it.
    private static func copyFile(at url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    // MARK: Prepared files

    /// Writes rendered image data to the share cache under a readable name.
    /// Prepared files older than an hour are removed first, so the cache does
    /// not grow while a recent share (an AirDrop still sending) keeps its file.
    static func prepareFile(_ data: Data, fileExtension: String) throws -> URL {
        let folder = StorageService.shareFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-3_600)
        let old = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in old where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("iSnap \(formatter.string(from: Date())).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
