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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    weak var model: AppModel? {
        didSet {
            model?.presentMainWindow = { [weak self] in self?.showApp() }
            model?.presentSettings = { [weak self] in self?.showSettings() }
            model?.captureLineController.onRevealedChange = { [weak self] isRevealed in
                self?.setDockIconVisible(isRevealed)
            }
            model?.startCaptureLine()
            applyStartupVisibilityIfNeeded()
            let links = pendingDeepLinks
            pendingDeepLinks.removeAll()
            links.forEach(handleDeepLink)
        }
    }
    private var statusItem: NSStatusItem?
    private var screenMenuItem: NSMenuItem?
    private var regionMenuItem: NSMenuItem?
    private var windowMenuItem: NSMenuItem?
    private var lineNowMenuItem: NSMenuItem?
    private var mainWindow: NSWindow?
    private var settingsPanel: NSPanel?
    private var appliedStartupVisibility = false
    private var pendingDeepLinks: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveDraft()
        model?.stopCaptureLine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.preserveCurrentDraft() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "isnap" || (url.isFileURL && url.pathExtension.lowercased() == "isnap") {
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
        menu.addItem(withTitle: String(localized: "Show iSnap"), action: #selector(showCaptureLine), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Screenshot Library"), action: #selector(showLibrary), keyEquivalent: "")
        menu.addItem(.separator())
        screenMenuItem = menu.addItem(withTitle: String(localized: "Capture Screen"), action: #selector(captureScreen), keyEquivalent: "")
        regionMenuItem = menu.addItem(withTitle: String(localized: "Capture Region"), action: #selector(captureRegion), keyEquivalent: "")
        windowMenuItem = menu.addItem(withTitle: String(localized: "Capture Window"), action: #selector(captureWindow), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Capture All Displays"), action: #selector(captureAll), keyEquivalent: "")
        menu.addItem(.separator())
        // Capture Line options live in a submenu, like Language.
        let lineMenu = NSMenu()
        for visibility in CaptureLineVisibility.allCases {
            let item = lineMenu.addItem(withTitle: visibility.title, action: #selector(chooseLineVisibility(_:)), keyEquivalent: "")
            item.representedObject = visibility.rawValue
        }
        lineMenu.addItem(.separator())
        lineNowMenuItem = lineMenu.addItem(withTitle: String(localized: "Show or Hide Now"), action: #selector(toggleCaptureLine), keyEquivalent: "")
        lineMenu.addItem(withTitle: String(localized: "Take Everything Down"), action: #selector(clearCaptureLine), keyEquivalent: "")
        for lineItem in lineMenu.items { lineItem.target = self }
        lineMenu.delegate = self
        let lineItem = NSMenuItem(title: String(localized: "Capture Line"), action: nil, keyEquivalent: "")
        lineItem.submenu = lineMenu
        menu.addItem(lineItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        let languageItem = NSMenuItem(title: String(localized: "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.target = self
            languageMenu.addItem(item)
        }
        languageMenu.delegate = self
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit iSnap"), action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.submenu == nil { menuItem.target = self }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let saved = AppLanguage.saved()
        for item in menu.items where item.action == #selector(chooseLanguage(_:)) {
            item.state = (item.representedObject as? String) == saved.rawValue ? .on : .off
        }
        guard let settings = model?.settings.value else { return }
        let visibility = settings.captureLine.visibility.rawValue
        for item in menu.items where item.action == #selector(chooseLineVisibility(_:)) {
            item.state = (item.representedObject as? String) == visibility ? .on : .off
        }
        // Shortcuts follow whatever is recorded in Settings.
        screenMenuItem?.showShortcut(settings.hotkeys.fullScreen)
        regionMenuItem?.showShortcut(settings.hotkeys.region)
        windowMenuItem?.showShortcut(settings.hotkeys.window)
        lineNowMenuItem?.showShortcut(settings.hotkeys.toggleCaptureLine)
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

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsPanel else { return }
        model?.isShowingSettings = false
        // Release the view so settings tasks stop when the popup closes.
        settingsPanel?.contentView = nil
    }

    @objc func showApp() {
        NSApp.unhide(nil)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showCaptureLine() {
        model?.showCaptureLineFromMenu()
    }

    private func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    @objc private func captureScreen() { Task { await model?.capture(.fullScreen) } }
    @objc private func captureAll() { Task { await model?.capture(.allDisplays) } }
    @objc private func captureRegion() { Task { await model?.capture(.region) } }
    @objc private func captureWindow() { Task { await model?.capture(.window) } }

    @objc private func toggleCaptureLine() { model?.toggleCaptureLine() }
    @objc private func chooseLineVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let visibility = CaptureLineVisibility(rawValue: raw) else { return }
        model?.setCaptureLineVisibility(visibility)
    }
    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        model?.setLanguage(language)
    }
    @objc private func clearCaptureLine() { model?.clearCaptureLine() }

    @objc private func showLibrary() {
        showApp()
        model?.section = .library
        Task { await model?.reloadLibrary() }
    }

    @objc private func showSettings() {
        guard let model else { return }
        if settingsPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            panel.identifier = NSUserInterfaceItemIdentifier("iSnap.settings")
            panel.title = String(localized: "Settings")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.delegate = self
            panel.center()
            settingsPanel = panel
        }
        guard let panel = settingsPanel else { return }
        if panel.contentView == nil || !model.isShowingSettings {
            panel.contentView = NSHostingView(rootView:
                SettingsView(store: model.settings, onClose: { [weak panel] in panel?.close() })
                    .environmentObject(model)
            )
        }
        // Activating a hidden app must not restore its editor along with Settings.
        if NSApp.isHidden { mainWindow?.orderOut(nil) }
        model.isShowingSettings = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleDeepLink(_ url: URL) {
        guard let model else { return }
        showApp()
        if url.isFileURL, url.pathExtension.lowercased() == "isnap" {
            model.openProject(at: url)
            return
        }
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
    @ObservedObject private var model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…", action: model.showSettings).keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Image…", action: model.openImage).keyboardShortcut("o")
            Button("Open Project…", action: model.openProject)
            Button("Paste Image", action: model.pasteImage).keyboardShortcut("v")
            Button("Insert Image Overlay…", action: model.insertOverlayImage)
                .disabled(model.document.image == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project…", action: model.saveProject).keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.document.image == nil)
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
                .disabled(model.section != .editor || model.document.selectedAnnotationIDs.isEmpty)
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
            Button("Screen Under Pointer") { Task { await model.capture(.fullScreen) } }
            Button("Region") { Task { await model.capture(.region) } }
            Button("Window") { Task { await model.capture(.window) } }
            Button("All Displays") { Task { await model.capture(.allDisplays) } }
            Button("Capture Last Region") { Task { await model.captureLastRegion() } }
                .disabled(model.lastRegion == nil || model.isCapturing)
            Button("Scrolling Capture…") { Task { await model.beginScrollingCapture() } }
                .disabled(model.isCapturing)
            Divider()
            Button("Extract Text from Screenshot") { Task { await model.parseScreenshot() } }
                .disabled(model.document.image == nil || model.isParsingScreenshot)
            Divider()
            Picker("Capture Line", selection: Binding(
                get: { settings.value.captureLine.visibility },
                set: { model.setCaptureLineVisibility($0) }
            )) {
                ForEach(CaptureLineVisibility.allCases) { Text($0.title).tag($0) }
            }
            Button("Show or Hide Capture Line Now", action: model.toggleCaptureLine)
            Button("Take Everything Down", action: model.clearCaptureLine)
        }
    }
}
