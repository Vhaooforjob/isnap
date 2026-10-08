import AppKit
import Combine
import os
import SwiftUI

private let log = Logger(subsystem: "dev.isnap.app", category: "CaptureLine")

/// Runs the Capture Line: a transparent strip under the menu bar where
/// recent captures hang. Its `CaptureLineVisibility` decides how it shows:
/// on hover it waits above the top edge, slides down when the pointer rests
/// in the menu bar and peeks after each capture; always keeps it down; hide
/// keeps it up until the shortcut asks for it. It never hangs across a full
/// screen app.
/// Behavior adapted from Tendedero (MIT), see THIRD_PARTY_NOTICES.md.
@MainActor
final class CaptureLineController: ObservableObject {
    let line: CaptureLine

    /// The folder macOS screenshots are picked up from, when watching.
    @Published private(set) var screenshotFolder: URL?
    /// False when that folder cannot be read, usually missing Desktop access.
    @Published private(set) var canReadScreenshotFolder = true

    private var settings = AppSettings.CaptureLineSettings()
    private var isStarted = false
    private var panel: CaptureLinePanel?
    private var watcher: ScreenshotFolderWatcher?
    /// While routing, a second watcher on the Desktop: if a macOS version
    /// ignores the screenshot settings, captures still hang on the line.
    private var safetyWatcher: ScreenshotFolderWatcher?
    private var clipboardWatcher: ClipboardScreenshotWatcher?
    private var routingApplied = false
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var clickMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var mouseTimer: Timer?
    private var locationTimer: Timer?
    /// Whether the line was down when the menu bar was last clicked. That
    /// click already tucks the line away, so a Show/Hide menu item uses
    /// this to know what the user saw when they opened the menu.
    private(set) var wasRevealedAtMenuBarClick = false

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Opened on purpose: it stays down until the pointer has visited it
    /// and left, or the shortcut is pressed again.
    private var isPinned = false
    /// A new capture shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    private var awaySince: Date?
    /// After a click in the menu bar the line stays hidden until the
    /// pointer leaves it, so it never comes down over an open menu.
    private var menuBarSuppressed = false
    /// Whether the line should be up if nothing prevents it.
    private var wanted = false
    /// Set when opened on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?
    /// Keep-visible mode: hidden on purpose with the shortcut or the menu,
    /// until shown again or a new capture arrives.
    private var hiddenByUser = false

    /// How long the pointer rests in the menu bar before the line comes down.
    private static let revealDelay: TimeInterval = 0.25
    /// How long the pointer is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    init(line: CaptureLine) {
        self.line = line
    }

    var isRevealed: Bool { line.isRevealed }


    // MARK: Lifecycle

    func start(with settings: AppSettings.CaptureLineSettings) {
        guard !isStarted else { return apply(settings) }
        isStarted = true
        self.settings = settings
        line.playsSounds = settings.playsSounds

        let host = NSHostingView(rootView: CaptureLineView(line: line))
        host.sizingOptions = []
        let panel = CaptureLinePanel(content: host)
        self.panel = panel
        panel.placeOnScreen()
        updateCapacity()

        line.onFall = { [weak self] item in self?.fall(item) }
        SystemMarkupService.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space; check again once
        // the switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.placeOnScreen()
                self?.updateCapacity()
            }
        })

        restoreRoutingOnTermination()
        watchClicks()
        applySources()
        // ⇧⌘5 can change the save location at any time; follow it.
        let locationTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followScreenshotLocation() }
        }
        RunLoop.main.add(locationTimer, forMode: .common)
        self.locationTimer = locationTimer
        lastLiveCount = line.liveCount
        if line.liveCount > 0 && settings.isEnabled {
            wanted = true
            refresh()
        }
    }

    func apply(_ newValue: AppSettings.CaptureLineSettings) {
        let old = settings
        settings = newValue
        line.playsSounds = newValue.playsSounds
        guard isStarted else { return }
        if old.isEnabled != newValue.isEnabled
            || old.hangsSystemScreenshots != newValue.hangsSystemScreenshots
            || old.routesSystemScreenshots != newValue.routesSystemScreenshots
            || old.hangsClipboardScreenshots != newValue.hangsClipboardScreenshots {
            applySources()
        }
        if old.visibility != newValue.visibility {
            hiddenByUser = false
            isPinned = false
            if newValue.visibility != .always { setRevealed(false) }
        }
        if !newValue.isEnabled {
            keepOpen = false
            wanted = false
            refresh()
        } else if line.liveCount > 0 {
            wanted = true
            refresh()
        }
    }

    /// Puts macOS screenshot settings back. Called when iSnap quits.
    func shutdown() {
        restoreRouting()
    }

    // MARK: Screenshot sources

    private var routesScreenshots: Bool {
        settings.isEnabled && settings.hangsSystemScreenshots && settings.routesSystemScreenshots
    }

    /// Retries reading the screenshot folder, for example after access to
    /// the Desktop was granted in System Settings.
    func retryScreenshotFolder() {
        applySources()
    }

    private func followScreenshotLocation() {
        guard let watcher, !routingApplied else { return }
        let current = ScreenshotFolderWatcher.systemScreenshotFolder()
        if current.standardizedFileURL != watcher.folder.standardizedFileURL { applySources() }
    }

    private func applySources() {
        watcher?.stop()
        safetyWatcher?.stop()
        clipboardWatcher?.stop()
        watcher = nil
        safetyWatcher = nil
        clipboardWatcher = nil
        screenshotFolder = nil
        canReadScreenshotFolder = true

        if routesScreenshots {
            SystemScreenshotRouting.apply(to: line.ownedFolder)
            routingApplied = true
        } else {
            restoreRouting()
        }
        if settings.isEnabled && settings.hangsClipboardScreenshots {
            let clipboard = ClipboardScreenshotWatcher { [weak self] data in self?.hangClipboardScreenshot(data) }
            clipboard.start()
            clipboardWatcher = clipboard
        }
        guard settings.isEnabled, settings.hangsSystemScreenshots else { return }

        let watcher = ScreenshotFolderWatcher(
            onNew: { [weak self] url in self?.hangSystemScreenshot(url) },
            onChange: { [weak self] in self?.line.prune() }
        )
        canReadScreenshotFolder = watcher.start()
        screenshotFolder = watcher.folder
        log.notice("Watching \(watcher.folder.path, privacy: .public), readable: \(self.canReadScreenshotFolder)")
        self.watcher = watcher
        if routingApplied,
           watcher.folder.standardizedFileURL != ScreenshotFolderWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotFolderWatcher(
                folder: ScreenshotFolderWatcher.desktop,
                onNew: { [weak self] url in self?.hangSystemScreenshot(url) },
                onChange: { [weak self] in self?.line.prune() }
            )
            safety.start()
            safetyWatcher = safety
        }
    }

    private func restoreRouting() {
        guard routingApplied else { return }
        SystemScreenshotRouting.restore(from: line.ownedFolder)
        routingApplied = false
    }

    /// Quitting from the menu runs applicationWillTerminate; a plain kill
    /// does not, so routing is also restored on these signals.
    private func restoreRoutingOnTermination() {
        for value in [SIGTERM, SIGINT, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.restoreRouting() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func hangSystemScreenshot(_ url: URL) {
        log.notice("macOS screenshot \(url.lastPathComponent, privacy: .public)")
        hang(url, from: ScreenshotFolderWatcher.captureRect(of: url))
    }

    /// A clipboard screenshot has no file; it becomes a line-only capture.
    private func hangClipboardScreenshot(_ data: Data) {
        let folder = line.ownedFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = CaptureLine.uniqueURL(in: folder, for: "Screenshot \(Self.clipboardTimestamp.string(from: Date())).png")
            try data.write(to: url, options: .atomic)
            log.notice("Clipboard screenshot saved as \(url.lastPathComponent, privacy: .public)")
            hang(url, from: nil)
        } catch {
            log.error("Could not save clipboard screenshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let clipboardTimestamp: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return value
    }()

    // MARK: Hanging

    /// A new capture lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    func hang(_ url: URL, from rect: CGRect?) {
        guard isStarted, settings.isEnabled else { return }
        hiddenByUser = false
        if let rect {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: rect != nil), let rect else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: rect)
        }
    }

    private func fly(_ id: UUID, from rect: CGRect) {
        guard isPresent, line.isRevealed, let panel, let screen = panel.screen,
              let target = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(rect.width, rect.height) * screen.backingScaleFactor)
        guard let image = ImageIOService.thumbnail(at: item.url, maxPixelSize: min(3000, max(400, pixels))) else {
            line.land(id)
            return
        }
        CaptureLineFlight.fly(image: image, from: rect, to: target, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: HangingCapture) {
        guard isPresent, line.isRevealed, !item.isFlying, let screen = panel?.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureLineFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card hangs, in screen coordinates, using the line's layout.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let panel, let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = CaptureLineLayout.x(index: index, count: line.items.count, width: width)
        let viewTop = CaptureLineLayout.ropeY(x: x, width: width) - CaptureLineLayout.pinAbove
        let cardTop = viewTop + CaptureLineLayout.cardOffsetBelowTop
        let size = CaptureLineLayout.cardSize(for: line.items[index].thumbnail.size)
        return CGRect(
            x: panel.frame.minX + x - size.width / 2,
            y: panel.frame.maxY - cardTop - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel?.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = settings.isEnabled
            refresh()
            // Hidden means hidden: new captures hang without coming down.
            if settings.visibility != .hidden { reveal(peekFor: 2.5) }
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    /// "Show or Hide Now" chosen from a menu. Outside Always Show, opening a
    /// menu bar menu already tucked the line away, so "hide" means leaving
    /// it that way.
    func toggleFromMenu() {
        guard isStarted, settings.isEnabled else { return }
        if settings.visibility != .always && wasRevealedAtMenuBarClick {
            wasRevealedAtMenuBarClick = false
            hide()
        } else {
            toggle()
        }
    }

    func toggle() {
        guard isStarted, settings.isEnabled else { return }
        if line.isRevealed {
            hiddenByUser = true
            hide()
        } else {
            hiddenByUser = false
            keepOpen = true
            wanted = true
            panel?.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    func clear() {
        line.clear()
    }

    /// Tucks the line away; an empty line opened on purpose goes away too.
    private func hide() {
        setRevealed(false)
        keepOpen = false
        if line.liveCount == 0 {
            wanted = false
            refresh()
        }
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        guard let panel else { return }
        let blocked = (panel.screen ?? CaptureLinePanel.screenUnderPointer()).map(FullScreenSpace.isActive(on:)) ?? false
        if wanted && !blocked { present() } else { dismiss() }
        // The pointer is watched while there is a line, even tucked away,
        // to notice it resting in the menu bar.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent, let panel else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { isPinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        line.prune()
        setRevealed(true)
    }

    private func setRevealed(_ revealed: Bool) {
        guard revealed != line.isRevealed else { return }
        log.debug("Line \(revealed ? "down" : "up", privacy: .public)")
        line.isRevealed = revealed
        if !revealed {
            isPinned = false
            peekUntil = .distantPast
            panel?.ignoresMouseEvents = true
        }
    }

    private func updateCapacity() {
        guard let panel else { return }
        line.maxItems = CaptureLineLayout.capacity(width: panel.frame.width)
    }

    // MARK: Pointer

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    private static func menuBarBand(of screen: NSScreen) -> NSRect {
        var height = screen.frame.maxY - screen.visibleFrame.maxY
        if height < 1 { height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    /// A click anywhere but on a card puts the line away: in the menu bar,
    /// in another app, or on the desktop.
    private func watchClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                let inMenuBar = NSScreen.screens.contains { NSMouseInRect(point, Self.menuBarBand(of: $0), false) }
                // Always Show ignores clicks: only the shortcut or the menu hides it.
                guard self.settings.visibility != .always else { return }
                if inMenuBar {
                    self.wasRevealedAtMenuBarClick = self.line.isRevealed
                    self.menuBarSuppressed = true
                    self.hotZoneSince = nil
                }
                guard self.line.isRevealed, !CaptureGrabView.isDragging,
                      inMenuBar || !self.isOverCard(point) else { return }
                self.hide()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            handler(event)
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel?.ignoresMouseEvents = true
    }

    private func tick() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()
        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        if settings.visibility == .always {
            // Down whenever there is something to show, unless hidden on
            // purpose; it comes back after a full screen app is left.
            if !line.isRevealed {
                if isPresent && !hiddenByUser { reveal() }
                return
            }
            awaySince = nil
            updateMousePassThrough(mouse)
            return
        }

        guard line.isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            if settings.visibility == .onHover, let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreenSpace.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && isPinned { isPinned = false }

        let busy = isPinned || CaptureGrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    private func isOverCard(_ mouse: NSPoint) -> Bool {
        guard let panel, isPresent else { return false }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
    }

    /// The panel spans the whole screen width, so it only accepts the mouse
    /// while the pointer is over a card. Everywhere else clicks go through.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard let panel, !CaptureGrabView.isDragging else { return }
        let overCard = isOverCard(mouse)
        if panel.ignoresMouseEvents == overCard {
            panel.ignoresMouseEvents = !overCard
        }
    }
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets
/// clicks through everywhere except over the cards.
private final class CaptureLinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // iSnap hides itself while capturing; the line lives on regardless.
        canHide = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen with the pointer: that is where the
    /// capture was just taken.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? Self.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(
            x: visible.minX,
            y: visible.maxY - CaptureLineLayout.panelHeight,
            width: visible.width,
            height: CaptureLineLayout.panelHeight
        )
        if frame != target { setFrame(target, display: true) }
    }
}

// The window server knows the type of Space each display shows. These calls
// are private but long stable, need no permission, and are what window
// managers rely on. A full screen Space is type 4.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

private enum FullScreenSpace {
    private static let fullScreenSpaceType = 4

    /// True when the screen is showing a full screen app, such as a video
    /// or a presentation: the line never hangs across those.
    static func isActive(on screen: NSScreen) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]],
              !displays.isEmpty else { return false }
        // With "Displays have separate Spaces" off there is a single entry.
        let entry: [String: Any]?
        if displays.count == 1 {
            entry = displays.first
        } else {
            let uuid = uuidString(for: screen)
            entry = displays.first { ($0["Display Identifier"] as? String) == uuid }
        }
        let current = entry?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == fullScreenSpaceType
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
