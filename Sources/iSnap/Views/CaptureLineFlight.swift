import AppKit
import QuartzCore

/// A capture lifting off from where it was taken and flying up to its place
/// on the line. It turns into the hanging card on the way: it shrinks, tilts
/// and grows its glass frame and clip, so nothing changes on landing. The
/// same layers draw a discarded card falling over the whole screen.
/// Adapted from Tendedero (MIT).
@MainActor
final class CaptureLineFlight {
    private static let flightDuration: CFTimeInterval = 0.65
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30
    private static var current: [CaptureLineFlight] = []

    private let window: NSWindow
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()

    private let from: CGRect
    private let to: CGRect
    private let tilt: CGFloat
    private var isFalling = false
    private var duration = CaptureLineFlight.flightDuration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's unrotated frame on the line, in screen coordinates.
    ///   - tilt: the card's resting tilt in degrees, clockwise as SwiftUI uses.
    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let flight = CaptureLineFlight(image: image, from: from, to: to, tilt: tilt, screen: screen)
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A discarded card falls 520 points, tilting further and fading.
    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {
        let flight = CaptureLineFlight(image: image, from: card, to: card, tilt: tilt, screen: screen)
        flight.isFalling = true
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, screen: NSScreen) {
        self.from = from
        self.to = to
        self.tilt = tilt
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1) // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        glass.backgroundColor = NSColor(white: 0.97, alpha: 0.72).cgColor
        edge.colors = [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        edge.startPoint = CGPoint(x: 0.5, y: 1)
        edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 1.5
        edge.mask = edgeMask

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true

        clip.colors = [0.70, 0.93, 0.82, 0.62].map { NSColor(white: $0, alpha: 1).cgColor }
        clip.locations = [0, 0.35, 0.65, 1]
        clip.startPoint = CGPoint(x: 0, y: 0.5)
        clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip] as [CALayer] { layer.contentsScale = scale }
        container.addSublayer(glass)
        container.addSublayer(photo)
        container.addSublayer(edge)
        container.addSublayer(clip)
        host.layer?.addSublayer(container)
    }

    private func run() {
        if isFalling {
            update(1)
            updateFall(0)
        } else {
            update(0)
        }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let progress = min(1, (CACurrentMediaTime() - start) / duration)
        if isFalling { updateFall(progress) } else { update(progress) }
        guard progress >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if isFalling {
            window.orderOut(nil)
            return
        }
        // The real card fades in underneath; this one fades out over it.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateFall(_ raw: Double) {
        let eased = CGFloat(raw * raw * raw)
        let origin = window.frame.origin
        let angle = tilt + (tilt * 7 + 20) * eased
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * eased)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - eased)
        CATransaction.commit()
    }

    private func update(_ raw: Double) {
        let k = CGFloat(Self.easeInOutCubic(raw))
        let chrome = Float(Self.smooth(Double(k), 0.35, 1))
        let origin = window.frame.origin
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let width = lerp(from.width, to.width), height = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let inset = CaptureLineLayout.cardInset * k
        let radius = lerp(0, CaptureLineLayout.cardRadius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        container.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * k))
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        glass.frame = container.bounds
        glass.cornerRadius = radius
        glass.opacity = chrome
        edge.frame = container.bounds
        let edgeRadius = max(0, radius - 0.75)
        edgeMask.path = CGPath(
            roundedRect: container.bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: edgeRadius,
            cornerHeight: edgeRadius,
            transform: nil
        )
        edge.opacity = chrome
        photo.frame = container.bounds.insetBy(dx: inset, dy: inset)
        photo.cornerRadius = max(0, radius - inset)
        // The clip grips the top edge: 26 points tall, 12 of them over the card.
        clip.frame = CGRect(x: width / 2 - 4.5, y: height - 12, width: 9, height: 26)
        clip.opacity = chrome
        CATransaction.commit()
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
