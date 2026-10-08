import AppKit
import SwiftUI

// The Capture Line's visuals and gestures. Adapted from Tendedero (MIT),
// see THIRD_PARTY_NOTICES.md.

enum CaptureLineLayout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
    static let cardRadius: CGFloat = 16
    static let cardInset: CGFloat = 4
    /// Distance from the top of a hanging view (the clip) to its card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let fraction = x / width
        return ropeTop + 4 * sag(width: width) * fraction * (1 - fraction)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }

    /// How many cards fit across a screen of the given width.
    static func capacity(width: CGFloat) -> Int {
        max(3, min(12, Int((width - 200) / spacing)))
    }

    /// The photo fits inside the card keeping its proportions.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxWidth = cardWidth - 14, maxHeight: CGFloat = 104
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    static func cardSize(for size: CGSize) -> CGSize {
        let photo = photoSize(for: size)
        return CGSize(width: photo.width + cardInset * 2, height: photo.height + cardInset * 2)
    }
}

struct CaptureLineView: View {
    @ObservedObject var line: CaptureLine

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                CaptureLineRope(width: width)

                if line.items.isEmpty {
                    Text("Capture something and it will hang here")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: width / 2, y: CaptureLineLayout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = CaptureLineLayout.x(index: index, count: line.items.count, width: width)
                    let ropeY = CaptureLineLayout.ropeY(x: x, width: width)
                    let height = CaptureLineLayout.panelHeight - ropeY
                    HangingCaptureView(item: item, line: line)
                        .frame(width: CaptureLineLayout.cardWidth, height: height, alignment: .top)
                        .position(x: x, y: ropeY - CaptureLineLayout.pinAbove + height / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.isRevealed ? 0 : -(CaptureLineLayout.panelHeight + 12))
            .animation(
                line.isRevealed ? .spring(response: 0.42, dampingFraction: 0.82) : .easeIn(duration: 0.22),
                value: line.isRevealed
            )
        }
        .coordinateSpace(name: CaptureLineView.space)
        .onPreferenceChange(CaptureLineHitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }

    static let space = "captureLine"
}

/// One capture with its clip: it drops onto the line, swings, sways with
/// the breeze, and falls when taken down.
private struct HangingCaptureView: View {
    let item: HangingCapture
    @ObservedObject var line: CaptureLine

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }
    private var photoSize: CGSize { CaptureLineLayout.photoSize(for: item.thumbnail.size) }
    private var photoRadius: CGFloat { CaptureLineLayout.cardRadius - CaptureLineLayout.cardInset }

    var body: some View {
        VStack(spacing: -12) {
            CaptureLineClip().zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // The fall is drawn over the whole screen by CaptureLineFlight, so
        // the card here steps aside at once.
        .opacity(item.isFalling || item.isFlying ? 0 : (arrived ? 1 : 0))
        .transaction { if item.isFalling { $0.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.isFlying)
        .onAppear(perform: arrive)
        .onChange(of: item.isFlying) { was, now in if was && !now { nudge(2.2) } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    private var card: some View {
        Image(nsImage: item.thumbnail)
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width, height: photoSize.height)
            .clipShape(RoundedRectangle(cornerRadius: photoRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: photoRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .padding(CaptureLineLayout.cardInset)
            .captureLineGlass(cornerRadius: CaptureLineLayout.cardRadius)
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // Holding presses the card in slowly, building up to Markup.
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.035 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through CaptureGrabView, which sits on top.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .captureLineGlass(circle: true)
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(CaptureGrabArea(item: item, line: line))
            .overlay(alignment: .bottom) {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .captureLineGlass(capsule: true)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: CaptureLineHitRectsKey.self,
                        value: item.isFalling ? [:] : [item.id: geometry.frame(in: .named(CaptureLineView.space))]
                    )
                }
            )
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.isFlying {
            arrived = true
            return
        }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    private func breeze() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0...0.35)) {
            nudge(.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

/// A thin neutral rope that reads on light and dark wallpapers alike and
/// fades out at both ends, as if it came from beyond the screen.
private struct CaptureLineRope: View {
    let width: CGFloat

    private var path: Path {
        Path { path in
            let top = CaptureLineLayout.ropeTop
            path.move(to: CGPoint(x: -20, y: top))
            path.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * CaptureLineLayout.sag(width: width))
            )
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

/// A brushed aluminium clip with a slot where it grips the rope.
private struct CaptureLineClip: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(LinearGradient(
                stops: [
                    .init(color: Color(white: 0.70), location: 0),
                    .init(color: Color(white: 0.93), location: 0.35),
                    .init(color: Color(white: 0.82), location: 0.65),
                    .init(color: Color(white: 0.62), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.6
                    )
            )
            .overlay(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.32)).frame(width: 5, height: 1.4).padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}

struct CaptureLineHitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Crisp glass: the system blurred material with a thin specular edge.
    func captureLineGlass(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(
                LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            ))
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

// MARK: - Gestures

/// Bridges each card to AppKit drag and drop so it can be dragged into any
/// app as a real file:
///
/// - An app gets a copy, and the card stays on the line.
/// - A folder keeps a line-only capture, and the card leaves the line.
///   Library files are copied, so the Library is never emptied by a drag.
/// - The Trash discards it.
///
/// Click copies, double-click edits in iSnap, press and hold opens Markup,
/// and the corner cross takes the card down.
private struct CaptureGrabArea: NSViewRepresentable {
    let item: HangingCapture
    let line: CaptureLine

    func makeNSView(context: Context) -> CaptureGrabView {
        let view = CaptureGrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: CaptureGrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: CaptureGrabView) {
        let id = item.id
        let line = line
        let isOwned = line.isOwned(item.url)
        view.url = item.url
        view.dragImage = item.thumbnail
        view.allowsMove = isOwned
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.edit(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { line.pressedID = $0 ? id : nil }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is kept where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(CaptureLineMenuItem("Copy") { line.copy(id) })
            menu.addItem(CaptureLineMenuItem("Edit in iSnap") { line.edit(id) })
            menu.addItem(CaptureLineMenuItem("Markup") { line.markup(id) })
            menu.addItem(CaptureLineMenuItem("Open in Default App") { line.openExternally(id) })
            menu.addItem(CaptureLineMenuItem("Show in Finder") { line.reveal(id) })
            if isOwned {
                menu.addItem(CaptureLineMenuItem("Save to Desktop") { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if isOwned {
                menu.addItem(CaptureLineMenuItem("Discard") { line.discard(id) })
            } else {
                menu.addItem(CaptureLineMenuItem("Take Down") { line.discard(id) })
                menu.addItem(CaptureLineMenuItem("Move to Trash") { line.trash(id) })
            }
            return menu
        }
    }
}

final class CaptureGrabView: NSView, NSDraggingSource {
    static var isDragging = false

    var url: URL?
    var dragImage: NSImage?
    var allowsMove = false
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// Long enough not to fire on a slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45
    /// The discard cross drawn in the card's top-left corner.
    private static let crossHitSize: CGFloat = 26

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func isInCross(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let corner = NSRect(
            x: 0,
            y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
            width: Self.crossHitSize,
            height: Self.crossHitSize
        )
        return corner.contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, !didLongPress, let url else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        startedDrag = true
        endPress()

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        Self.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move for line-only captures, so a
        // folder keeps the file. Delete lets the Dock's Trash accept it.
        guard context == .outsideApplication else { return [] }
        return allowsMove ? [.copy, .move, .delete] : [.copy, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.isDragging = false
        startedDrag = false
        downPoint = nil
        // Dropped on the Trash: macOS only reports it; moving the file is ours.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later; check again then.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

final class CaptureLineMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String.LocalizationValue, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: String(localized: title), action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
