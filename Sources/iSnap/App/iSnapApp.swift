import AppKit
import SwiftUI

@main
struct iSnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .background {
                    WindowAccessor { window in
                        appDelegate.registerMainWindow(window)
                    }
                }
                .onAppear {
                    appDelegate.model = model
                    if model.settings.value.update.checkOnStartup { Task { await model.checkForUpdates() } }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            iSnapCommands(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel? {
        didSet {
            model?.presentMainWindow = { [weak self] in self?.showApp() }
            applyStartupVisibilityIfNeeded()
            let links = pendingDeepLinks
            pendingDeepLinks.removeAll()
            links.forEach(handleDeepLink)
        }
    }
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var appliedStartupVisibility = false
    private var pendingDeepLinks: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "isnap" {
            if model == nil {
                pendingDeepLinks.append(url)
            } else {
                handleDeepLink(url)
            }
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "iSnap")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show iSnap", action: #selector(showApp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Capture All Displays", action: #selector(captureAll), keyEquivalent: "")
        menu.addItem(withTitle: "Capture Region", action: #selector(captureRegion), keyEquivalent: "")
        menu.addItem(withTitle: "Capture Window", action: #selector(captureWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Screenshot Library", action: #selector(showLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit iSnap", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    func registerMainWindow(_ window: NSWindow) {
        guard window != mainWindow else { return }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("iSnap.mainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        applyStartupVisibilityIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == mainWindow else { return true }
        if model?.settings.value.startup.closeToMenuBar == true {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    @objc func showApp() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func captureAll() { Task { await model?.capture(.fullScreen) } }
    @objc private func captureRegion() { Task { await model?.capture(.region) } }
    @objc private func captureWindow() { Task { await model?.capture(.window) } }

    @objc private func showLibrary() {
        showApp()
        model?.section = .library
        Task { await model?.reloadLibrary() }
    }

    @objc private func showSettings() {
        showApp()
        model?.isShowingSettings = true
    }

    private func handleDeepLink(_ url: URL) {
        guard let model else { return }
        showApp()
        switch url.host {
        case "editor":
            model.section = .editor
        case "library":
            model.section = .library
            Task { await model.reloadLibrary() }
        case "open", "trash":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "name" })?
                .value
            guard let name else { return }
            Task {
                await model.reloadLibrary()
                guard let item = model.libraryItems.first(where: { $0.name == name }) else { return }
                if url.host == "open" {
                    model.openLibraryItem(item)
                } else {
                    await model.deleteLibraryItem(item)
                    model.section = .library
                }
            }
        default:
            break
        }
    }

    private func applyStartupVisibilityIfNeeded() {
        guard !appliedStartupVisibility, let model, let mainWindow else { return }
        appliedStartupVisibility = true
        if model.settings.value.startup.startHidden {
            mainWindow.orderOut(nil)
        } else {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
    }
}

private struct iSnapCommands: Commands {
    let model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image…", action: model.openImage).keyboardShortcut("o")
            Button("Paste Image", action: model.pasteImage).keyboardShortcut("v")
            Button("Insert Image Overlay…", action: model.insertOverlayImage)
                .disabled(model.document.image == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Edited Image", action: model.quickSave)
                .editorKeyboardShortcut(EditorKeyboardShortcut.parse(settings.value.hotkeys.saveEditedImage))
                .disabled(model.document.image == nil)
            Button("Export…", action: model.saveAs).keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.document.image == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Edited Image", action: model.copy)
                .editorKeyboardShortcut(EditorKeyboardShortcut.parse(settings.value.hotkeys.copyEditedImage))
                .disabled(model.document.image == nil)
        }
        CommandGroup(after: .undoRedo) {
            Button("Delete Annotation", action: model.document.deleteSelection).keyboardShortcut(.delete, modifiers: [])
            Divider()
            Button("Select Tool") { model.document.tool = .select }.keyboardShortcut("v", modifiers: [])
            Button("Rectangle Tool") { model.document.tool = .rectangle }.keyboardShortcut("r", modifiers: [])
            Button("Ellipse Tool") { model.document.tool = .ellipse }.keyboardShortcut("e", modifiers: [])
            Button("Arrow Tool") { model.document.tool = .arrow }.keyboardShortcut("a", modifiers: [])
            Button("Line Tool") { model.document.tool = .line }.keyboardShortcut("l", modifiers: [])
            Button("Text Tool") { model.document.tool = .text }.keyboardShortcut("t", modifiers: [])
            Button("Number Tool") { model.document.tool = .number }.keyboardShortcut("n", modifiers: [])
            Button("Spotlight Tool") { model.document.tool = .spotlight }.keyboardShortcut("s", modifiers: [])
            Button("Crop Tool") { model.document.tool = .crop }.keyboardShortcut("c", modifiers: [])
        }
        CommandMenu("Capture") {
            Button("All Displays") { Task { await model.capture(.fullScreen) } }
            Button("Region") { Task { await model.capture(.region) } }
            Button("Window") { Task { await model.capture(.window) } }
        }
    }
}
