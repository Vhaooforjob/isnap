import AppKit
import SwiftUI

// The Capture Line's visuals and gestures. Adapted from Tendedero (MIT),
// see THIRD_PARTY_NOTICES.md.

enum CaptureLineLayout {
    static let classicPanelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let catRopeTop: CGFloat = 56
    static let catRopeSag: CGFloat = 10
    static let rabbitRopeTop: CGFloat = 82
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
    static let cardRadius: CGFloat = 16
    static let cardInset: CGFloat = 4
    /// Distance from the top of a hanging view (the clip) to its card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    static let panelHeight: CGFloat = classicPanelHeight

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeTop(for style: CaptureLineStyle) -> CGFloat {
        switch style {
        case .classic: ropeTop
        case .cats: catRopeTop
        case .rabbits: rabbitRopeTop
        case .spiderMan: 82
        }
    }

    static func ropeY(x: CGFloat, width: CGFloat, style: CaptureLineStyle = .classic) -> CGFloat {
        let top = ropeTop(for: style)
        guard width > 0 else { return top }
        let fraction = x / width
        let sag = ropeSag(width: width, style: style)
        return top + 4 * sag * fraction * (1 - fraction)
    }

    static func ropeSag(width: CGFloat, style: CaptureLineStyle) -> CGFloat {
        style == .classic ? sag(width: width) : catRopeSag
    }

    static func catRopeY(x: CGFloat, width: CGFloat) -> CGFloat {
        ropeY(x: x, width: width, style: .cats)
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

    static func cardSize(for size: CGSize, style: CaptureLineStyle = .classic) -> CGSize {
        let photo = photoSize(for: size)
        let inset: CGFloat = style.usesIllustratedRope ? 2 : cardInset
        return CGSize(width: photo.width + inset * 2, height: photo.height + inset * 2)
    }

    static func cardOffsetBelowTop(for style: CaptureLineStyle) -> CGFloat {
        // Illustrated clips are 21 points high; classic clips are 26.
        style.usesIllustratedRope ? 21 - 12 : cardOffsetBelowTop
    }
}

struct CaptureLineView: View {
    @ObservedObject var line: CaptureLine

    private let catCenters: [CGFloat] = [0.16, 0.48, 0.84]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let panelHeight = CaptureLineLayout.panelHeight
            ZStack(alignment: .topLeading) {
                CaptureLineRope(
                    width: width,
                    top: CaptureLineLayout.ropeTop(for: line.style),
                    sag: CaptureLineLayout.ropeSag(width: width, style: line.style),
                    style: line.style
                )

                if line.style == .cats {
                    CatRopeArtwork(width: width, centers: catCenters)
                        .transition(.opacity)
                } else if line.style == .rabbits {
                    RabbitRopeArtwork(width: width, isActive: line.isRevealed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                } else if line.style == .spiderMan {
                    SpiderWebArtwork(width: width, isActive: line.isRevealed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }

                if line.items.isEmpty && line.style == .classic {
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
                    let ropeY = CaptureLineLayout.ropeY(x: x, width: width, style: line.style)
                    let height = panelHeight - ropeY
                    HangingCaptureView(item: item, line: line)
                        .frame(width: CaptureLineLayout.cardWidth, height: height, alignment: .top)
                        .position(x: x, y: ropeY - CaptureLineLayout.pinAbove + height / 2)
                }

                if line.style == .cats {
                    RunningCatView(width: width, isActive: line.isRevealed)
                        .allowsHitTesting(false)
                        .zIndex(2)
                } else if line.style == .rabbits {
                    RunningRabbitView(width: width, isActive: line.isRevealed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(.easeInOut(duration: 0.28), value: line.style)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.isRevealed ? 0 : -(panelHeight + 12))
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

/// Three compact cat cutouts rest on the line and sway gently above the cards.
private struct CatRopeArtwork: View {
    let width: CGFloat
    let centers: [CGFloat]

    private var catSize: CGFloat { min(120, max(108, width * 0.08)) }

    var body: some View {
        ForEach(0..<3, id: \.self) { index in
            let x = width * centers[index]
            let ropeY = CaptureLineLayout.catRopeY(x: x, width: width)
            CatRopeCat(index: index, size: catSize)
                .position(x: x, y: ropeY - catSize * 0.25)
        }
    }
}

private struct CatRopeCat: View {
    let index: Int
    let size: CGFloat

    @State private var isSwaying = false
    @State private var isHovered = false

    private var imageName: String {
        switch index {
        case 0: "CaptureLineCatOrange"
        case 1: "CaptureLineCatGray"
        default: "CaptureLineCatCalico"
        }
    }

    // The independent illustrations have slightly different transparent
    // margins, so enlarge the outer cats to give all three a similar size.
    private var imageWidth: CGFloat { size * (index == 1 ? 1 : 1.2) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isHovered)) { context in
            let idleAngle = isSwaying ? 0.7 : -0.7
            let wobble = sin(context.date.timeIntervalSinceReferenceDate * 18) * 8
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: imageWidth, height: size)
                .rotationEffect(.degrees(isHovered ? wobble : idleAngle), anchor: .bottom)
                .offset(y: isHovered ? CGFloat(abs(wobble)) * 0.2 : (isSwaying ? -1.5 : 1.5))
            }
        .scaleEffect(isHovered ? 1.08 : 1)
        .animation(.easeInOut(duration: 2.6 + Double(index) * 0.35).repeatForever(autoreverses: true), value: isSwaying)
        .animation(.spring(response: 0.24, dampingFraction: 0.55), value: isHovered)
        .onAppear { isSwaying = true }
        .onHover { isHovered = $0 }
    }
}

/// Runs from one end of the line to the other, then turns around and repeats.
private struct RunningCatView: View {
    let width: CGFloat
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            // A full out-and-back takes a full minute; each direction is a slow crawl.
            let cycle = 60.0
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let isHeadingRight = phase < 0.5
            let progress = isHeadingRight ? phase * 2 : (1 - phase) * 2
            let startX: CGFloat = 24
            let endX = max(startX, width - 24)
            let x = startX + CGFloat(progress) * (endX - startX)
            let ropeY = CaptureLineLayout.catRopeY(x: x, width: width)
            let stride = sin(context.date.timeIntervalSinceReferenceDate * 3)

            Image("RunningCat")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 30)
                .scaleEffect(x: isHeadingRight ? 1 : -1, y: CGFloat(1 + abs(stride) * 0.035))
                .rotationEffect(.degrees(stride * 1.8))
                .position(x: x, y: ropeY - 10 + CGFloat(abs(stride)) * 1.2)
        }
    }
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
            if line.style == .spiderMan {
                CaptureLineWebClip().zIndex(1)
            } else if line.style.usesIllustratedRope {
                CaptureLinePawClip(style: line.style).zIndex(1)
            } else {
                CaptureLineClip().zIndex(1)
            }
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
            .clipShape(RoundedRectangle(cornerRadius: line.style.usesIllustratedRope ? 4 : photoRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: line.style.usesIllustratedRope ? 4 : photoRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .captureLineCardSurface(style: line.style)
            .shadow(
                color: line.style.usesIllustratedRope
                    ? Color(red: 0.38, green: 0.24, blue: 0.18).opacity(hovering ? 0.22 : 0.12)
                    : .black.opacity(hovering ? 0.26 : 0.18),
                radius: line.style.usesIllustratedRope ? (hovering ? 7 : 4) : (hovering ? 14 : 10),
                y: line.style.usesIllustratedRope ? (hovering ? 5 : 3) : (hovering ? 8 : 5)
            )
            // Holding presses the card in slowly, building up to Markup.
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.035 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through CaptureGrabView, which sits on top.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(line.style.usesIllustratedRope ? Color(red: 0.40, green: 0.27, blue: 0.22) : .primary)
                    .frame(width: 20, height: 20)
                    .captureLineDecorativeSurface(style: line.style, circle: true)
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                // Share, mirroring the cross; also clicked through CaptureGrabView.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(line.style.usesIllustratedRope ? Color(red: 0.40, green: 0.27, blue: 0.22) : .primary)
                    .offset(y: -1)
                    .frame(width: 20, height: 20)
                    .captureLineDecorativeSurface(style: line.style, circle: true)
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
                        .captureLineDecorativeSurface(style: line.style, capsule: true)
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

/// A continuous cat rope and a thin neutral classic rope that fades at the edges.
private struct CaptureLineRope: View {
    let width: CGFloat
    var top = CaptureLineLayout.ropeTop
    var sag: CGFloat = 30
    var style: CaptureLineStyle = .classic

    private var path: Path {
        Path { path in
            path.move(to: CGPoint(x: -20, y: top))
            path.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * sag)
            )
        }
    }

    var body: some View {
        Group {
            if style == .spiderMan {
                ZStack {
                    path.stroke(Color(red: 0.16, green: 0.23, blue: 0.36).opacity(0.7), lineWidth: 3.5)
                    path.stroke(Color.white.opacity(0.95), lineWidth: 1.6)
                }
            } else if style.usesIllustratedRope {
                ZStack {
                    path.stroke(Color(red: 0.39, green: 0.25, blue: 0.19), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    path.stroke(Color(red: 0.91, green: 0.69, blue: 0.47), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    path.stroke(
                        Color(red: 0.68, green: 0.43, blue: 0.30),
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [2.2, 3.2])
                    )
                }
            } else {
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
            }
        }
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

private struct CaptureLinePawClip: View {
    var style: CaptureLineStyle = .cats

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(red: 0.98, green: 0.83, blue: 0.76))
            .frame(width: 17, height: 21)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color(red: 0.42, green: 0.27, blue: 0.22), lineWidth: 1.1)
            }
            .overlay {
                Group {
                    if style == .rabbits {
                        CaptureLineCarrot().frame(width: 10, height: 15)
                    } else {
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0.48, green: 0.30, blue: 0.24))
                    }
                }
            }
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

    @ViewBuilder
    func captureLineDecorativeSurface(style: CaptureLineStyle, circle: Bool = false, capsule: Bool = false) -> some View {
        if style.usesIllustratedRope {
            let shape: AnyShape = circle ? AnyShape(Circle())
                : capsule ? AnyShape(Capsule())
                : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            background(Color(red: 1.0, green: 0.91, blue: 0.80), in: shape)
                .overlay(shape.stroke(Color(red: 0.48, green: 0.31, blue: 0.24), lineWidth: 1))
        } else {
            captureLineGlass(circle: circle, capsule: capsule)
        }
    }

    @ViewBuilder
    func captureLineCardSurface(style: CaptureLineStyle) -> some View {
        if style == .spiderMan {
            padding(CaptureLineLayout.cardInset)
                .captureLineGlass(cornerRadius: CaptureLineLayout.cardRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: CaptureLineLayout.cardRadius)
                        .strokeBorder(LinearGradient(colors: [.red.opacity(0.8), .blue.opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
        } else if style.usesIllustratedRope {
            padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.98, green: 0.91, blue: 0.82))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(red: 0.80, green: 0.63, blue: 0.48).opacity(0.9), lineWidth: 1)
                )
        } else {
            padding(CaptureLineLayout.cardInset)
                .captureLineGlass(cornerRadius: CaptureLineLayout.cardRadius)
        }
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
/// the top-left cross takes the card down, and the top-right button shares.
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
        let url = item.url
        view.shareMenuProvider = { line.shareMenu?(url) }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(CaptureLineMenuItem("Copy") { line.copy(id) })
            menu.addItem(CaptureLineMenuItem("Edit in iSnap") { line.edit(id) })
            menu.addItem(CaptureLineMenuItem("Pin on Screen") { line.onPin?(url) })
            menu.addItem(CaptureLineMenuItem("Markup") { line.markup(id) })
            if let share = line.shareMenu?(url) {
                let shareItem = NSMenuItem(title: String(localized: "Share"), action: nil, keyEquivalent: "")
                shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                shareItem.submenu = share
                menu.addItem(shareItem)
            }
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
    /// A card's menu is open: the line must not tuck away underneath it.
    static var isShowingMenu = false

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
    var shareMenuProvider: () -> NSMenu? = { nil }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// Long enough not to fire on a slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45
    /// The discard cross drawn in the card's top-left corner.
    private static let crossHitSize: CGFloat = 26

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func corner(leading: Bool) -> NSRect {
        NSRect(
            x: leading ? 0 : bounds.width - Self.crossHitSize,
            y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
            width: Self.crossHitSize,
            height: Self.crossHitSize
        )
    }

    private func isIn(_ corner: NSRect, _ event: NSEvent) -> Bool {
        corner.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if isIn(corner(leading: true), event) {
            downPoint = nil
            onDiscard()
            return
        }
        if isIn(corner(leading: false), event), let menu = shareMenuProvider() {
            downPoint = nil
            let anchor = corner(leading: false)
            show(menu) {
                menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: isFlipped ? anchor.maxY : anchor.minY), in: self)
            }
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
        let menu = menuProvider()
        show(menu) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// Menus track synchronously; the flag covers the whole time one is open.
    private func show(_ menu: NSMenu, _ popUp: () -> Void) {
        Self.isShowingMenu = true
        defer { Self.isShowingMenu = false }
        popUp()
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

    /// A title that is already localized or is a name, such as an app's.
    init(verbatim title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
