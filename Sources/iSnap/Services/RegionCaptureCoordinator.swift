import AppKit

struct ScreenSelection {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

@MainActor
final class RegionCaptureCoordinator {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<ScreenSelection?, Never>?
    private var preparing = false
    private var previews: [CGDirectDisplayID: CGImage] = [:]

    func selectRegion() async -> ScreenSelection? {
        guard continuation == nil, !preparing else { return nil }
        preparing = true
        let service = CaptureService()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if let result = try? await service.capture(displayID: id, excludingOwnWindows: true),
               let cg = result.image.cgImage(forProposedRect: nil, context: nil, hints: nil) { previews[id] = cg }
        }
        preparing = false
        guard !Task.isCancelled else { previews.removeAll(); return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showOverlays()
        }
    }

    private func showOverlays() {
        NSApp.activate(ignoringOtherApps: true)
        windows = NSScreen.screens.map { screen in
            // With `screen:`, the content rect is relative to that screen's
            // origin. Passing the global frame pushed overlays on secondary
            // displays off screen, so only the main display could be selected.
            let window = SelectionWindow(
                contentRect: CGRect(origin: .zero, size: screen.frame.size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.preview = screen.displayID.flatMap { previews[$0] }
            view.pixelScale = screen.backingScaleFactor
            view.onComplete = { [weak self, weak screen] rect in
                guard let self, let screen else { return }
                let localFromTop = CGRect(
                    x: rect.minX,
                    y: screen.frame.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                let displayID = screen.displayID ?? 0
                self.finish(ScreenSelection(displayID: displayID, rect: localFromTop))
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            return window
        }
        // Escape goes to the key overlay: the one under the pointer.
        let pointerScreen = NSScreen.underPointer
        (windows.first { $0.screen == pointerScreen } ?? windows.first)?.makeKey()
    }

    private func finish(_ selection: ScreenSelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        previews.removeAll()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    func cancelSelection() { if continuation != nil { finish(nil) } }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    var preview: CGImage?
    var pixelScale: CGFloat = 1
    private var pointer: CGPoint?
    private var movingRegion = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil); needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        pointer = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateSelection(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        updateSelection(convert(event.locationInWindow, from: nil))
        let rect = Self.pixelAligned(selectionRect, scale: pixelScale).intersection(bounds)
        if rect.width >= 2, rect.height >= 2 { onComplete?(rect) }
        else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 49 { movingRegion = true }
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { movingRegion = false } else { super.keyUp(with: event) }
    }

    private func updateSelection(_ point: CGPoint) {
        let point = CGPoint(x: point.x.clamped(to: bounds.minX...bounds.maxX), y: point.y.clamped(to: bounds.minY...bounds.maxY))
        if movingRegion, let previous = pointer, let start, let current {
            let rect = selectionRect
            let dx = (point.x - previous.x).clamped(to: -rect.minX...(bounds.maxX - rect.maxX))
            let dy = (point.y - previous.y).clamped(to: -rect.minY...(bounds.maxY - rect.maxY))
            self.start = CGPoint(x: start.x + dx, y: start.y + dy)
            self.current = CGPoint(x: current.x + dx, y: current.y + dy)
        } else { current = point }
        pointer = point
    }

    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        let x = (rect.minX * scale).rounded(), y = (rect.minY * scale).rounded()
        return CGRect(x: x / scale, y: y / scale,
            width: ((rect.maxX * scale).rounded() - x) / scale,
            height: ((rect.maxY * scale).rounded() - y) / scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()
        defer { drawLoupe() }
        guard start != nil, current != nil else {
            drawHint(String(localized: "Drag to capture • Hold Space to move • Release to capture • Esc to cancel"))
            return
        }
        let rect = selectionRect
        NSGraphicsContext.current?.cgContext.setBlendMode(.copy)
        NSColor.clear.setFill()
        rect.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()
        drawSize(rect)
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func drawHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
    }

    private func drawSize(_ rect: CGRect) {
        let aligned = Self.pixelAligned(rect, scale: pixelScale)
        let text = "\(Int((aligned.width * pixelScale).rounded())) × \(Int((aligned.height * pixelScale).rounded())) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.75)
        ]
        text.draw(at: CGPoint(x: rect.minX, y: max(4, rect.minY - 22)), withAttributes: attributes)
    }

    private func drawLoupe() {
        guard let pointer, let preview else { return }
        let scaleX = CGFloat(preview.width) / bounds.width, scaleY = CGFloat(preview.height) / bounds.height
        let sample = CGRect(x: floor(pointer.x * scaleX) - 12, y: floor((bounds.height - pointer.y) * scaleY) - 12, width: 24, height: 24)
        let clipped = sample.intersection(CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
        guard let cg = preview.cropping(to: clipped) else { return }
        let rect = CGRect(x: min(max(8, pointer.x + 24), bounds.width - 128),
                          y: min(max(8, pointer.y + 24), bounds.height - 128), width: 120, height: 120)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.black.setFill(); rect.fill()
        let content = CGRect(x: rect.minX + (clipped.minX - sample.minX) * 5,
                             y: rect.minY + (sample.maxY - clipped.maxY) * 5,
                             width: clipped.width * 5, height: clipped.height * 5)
        NSImage(cgImage: cg, size: clipped.size).draw(in: content)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect); border.lineWidth = 3; border.stroke()
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: rect.midX, y: rect.minY)); cross.line(to: CGPoint(x: rect.midX, y: rect.maxY))
        cross.move(to: CGPoint(x: rect.minX, y: rect.midY)); cross.line(to: CGPoint(x: rect.maxX, y: rect.midY))
        cross.lineWidth = 1; cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

