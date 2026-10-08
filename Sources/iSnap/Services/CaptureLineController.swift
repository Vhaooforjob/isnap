import AppKit
import Combine
import SwiftUI

/// Runs the Capture Line: a transparent strip under the menu bar where
/// recent captures hang. It stays tucked above the top edge, slides down
/// when the pointer rests in the menu bar, peeks for a moment after each
/// capture, and hides while an app is in full screen.
/// Behavior adapted from Tendedero (MIT), see THIRD_PARTY_NOTICES.md.
@MainActor
final class CaptureLineController {
    let line: CaptureLine

    private var settings = AppSettings.CaptureLineSettings()
    private var isStarted = false
    private var panel: CaptureLinePanel?
    private var watcher: ScreenshotFolderWatcher?
    /// While routing, a second watcher on the Desktop: if a macOS version
    /// ignores the screenshot settings, captures still hang on the line.
    private var safetyWatcher: ScreenshotFolderWatcher?
    private var routingApplied = false
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var clickMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var mouseTimer: Timer?

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
        watchMenuBarClicks()
        applySources()
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
            || old.routesSystemScreenshots != newValue.routesSystemScreenshots {
            applySources()
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

    private func applySources() {
        watcher?.stop()
        safetyWatcher?.stop()
        watcher = nil
        safetyWatcher = nil

        if routesScreenshots {
            SystemScreenshotRouting.apply(to: line.ownedFolder)
            routingApplied = true
        } else {
            restoreRouting()
        }
        guard settings.isEnabled, settings.hangsSystemScreenshots else { return }

        let watcher = ScreenshotFolderWatcher(
            onNew: { [weak self] url in self?.hangSystemScreenshot(url) },
            onChange: { [weak self] in self?.line.prune() }
        )
        watcher.start()
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
        hang(url, from: ScreenshotFolderWatcher.captureRect(of: url))
    }

    // MARK: Hanging

    /// A new capture lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    func hang(_ url: URL, from rect: CGRect?) {
        guard isStarted, settings.isEnabled else { return }
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
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    func toggle() {
        guard isStarted, settings.isEnabled else { return }
        if line.isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
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

    /// A click anywhere in the menu bar of any screen puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(point, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.line.isRevealed {
                    self.isPinned = false
                    self.setRevealed(false)
                }
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

        guard line.isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            if settings.revealsFromMenuBar, let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
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

    /// The panel spans the whole screen width, so it only accepts the mouse
    /// while the pointer is over a card. Everywhere else clicks go through.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard let panel, !CaptureGrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overCard = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
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
