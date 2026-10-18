import SwiftUI

enum SpiderStandingPose: Int, CaseIterable {
    case singleHand, crouched, upward

    var upperTransform: CGAffineTransform {
        switch self {
        case .singleHand: .identity
        case .crouched: CGAffineTransform(translationX: 7.5, y: 28).scaledBy(x: 0.85, y: 0.85)
        case .upward: CGAffineTransform(translationX: 50, y: 108)
            .rotated(by: 0.22).scaledBy(x: 0.86, y: 0.86).translatedBy(x: -50, y: -102)
        }
    }

    func arms(aim: Double) -> [[CGPoint]] {
        let reach = CGFloat(aim)
        switch self {
        case .singleHand:
            return [[CGPoint(x: 34, y: 77), CGPoint(x: 24, y: 88), CGPoint(x: 30, y: 98)],
                    [CGPoint(x: 66, y: 77), CGPoint(x: 83, y: 92 - 22 * reach), CGPoint(x: 88 + 3 * reach, y: 76 - 18 * reach)]]
        case .crouched:
            return [[CGPoint(x: 34, y: 77), CGPoint(x: 17, y: 88 - 15 * reach), CGPoint(x: 14 - 6 * reach, y: 90 - 24 * reach)],
                    [CGPoint(x: 66, y: 77), CGPoint(x: 83, y: 88 - 15 * reach), CGPoint(x: 86 + 6 * reach, y: 90 - 24 * reach)]]
        case .upward:
            return [[CGPoint(x: 34, y: 77), CGPoint(x: 20, y: 88), CGPoint(x: 14, y: 103)],
                    [CGPoint(x: 66, y: 77), CGPoint(x: 82, y: 50), CGPoint(x: 74, y: 28 - 20 * reach)]]
        }
    }

    /// The renderer and web trails share the exact wrist positions and body transform.
    func webHands(aim: Double) -> [CGPoint] {
        let arms = arms(aim: aim)
        let wrists = self == .crouched ? [arms[0][2], arms[1][2]] : [arms[1][2]]
        return wrists.map { $0.applying(upperTransform) }
    }
}

struct SpiderDropEvent {
    let start: TimeInterval
    let duration: TimeInterval
    let anchorFraction: CGFloat
    let depth: CGFloat
    let bobAmplitude: CGFloat
    let frequency: Double
    let phase: Double

    static func random(start: TimeInterval) -> Self {
        // Use the gaps between the three permanent characters.
        let gap: CGFloat = Bool.random() ? 0.33 : 0.67
        return Self(start: start, duration: Double.random(in: 6...9),
                    anchorFraction: gap + CGFloat.random(in: -0.025...0.025),
                    depth: CGFloat.random(in: 18...24), bobAmplitude: CGFloat.random(in: 3...6),
                    frequency: Double.random(in: 2.1...3.3), phase: Double.random(in: 0...(2 * .pi)))
    }
}

enum SpiderSceneLayout {
    static let standingSize = CGSize(width: 44, height: 60)
    static let dropSize = CGSize(width: 34, height: 48)
    static let centers: [CGFloat] = [0.16, 0.5, 0.84]

    static func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    struct Shot {
        let aim: Double
        let reach: Double
        let opacity: Double
    }

    static func shot(time: TimeInterval, index: Int) -> Shot {
        let phase = (time + Double(index) * 1.8).truncatingRemainder(dividingBy: 6)
        return Shot(aim: smooth((phase - 0.3) / 0.4) * (1 - smooth((phase - 2) / 0.4)),
                    reach: smooth((phase - 0.8) / 0.35),
                    opacity: phase < 0.8 ? 0 : 1 - smooth((phase - 1.5) / 0.5))
    }

    struct DropPose {
        let anchor: CGPoint
        let attachment: CGPoint
        let angle: Double
    }

    static func drop(time: TimeInterval, width: CGFloat, event: SpiderDropEvent) -> DropPose? {
        let elapsed = time - event.start
        guard event.duration > 0, elapsed >= 0, elapsed < event.duration else { return nil }
        let progress = elapsed / event.duration
        let envelope = smooth(progress / 0.18) * (1 - smooth((progress - 0.78) / 0.22))
        let bob = sin(elapsed * event.frequency + event.phase)
        let hiddenY = -dropSize.height - 8
        let y = hiddenY + (event.depth + CGFloat(bob) * event.bobAmplitude - hiddenY) * envelope
        let angle = sin(elapsed * 1.7 + event.phase) * 0.18 * envelope
        let width = max(0, width)
        let gapIndex = event.anchorFraction < 0.5 ? 0 : 1
        let left = centers[gapIndex] * width
        let right = centers[gapIndex + 1] * width
        let middle = (left + right) / 2
        // Narrow displays leave less room for a random landing position.
        let excursion = dropSize.width / 2 + sin(0.18) * (event.depth + event.bobAmplitude + dropSize.height)
        let room = max(0, (right - left) / 2 - standingSize.width / 2 - excursion - 1)
        let anchor = CGPoint(x: min(middle + room, max(middle - room, width * event.anchorFraction)), y: 0)
        return DropPose(anchor: anchor,
                        attachment: CGPoint(x: anchor.x - sin(angle) * max(0, y), y: y),
                        angle: angle * 180 / .pi)
    }
}

/// The appearance is sampled once per visit, never randomized on every animation frame.
struct SpiderWebArtwork: View {
    let width: CGFloat
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var event: SpiderDropEvent?

    private var animates: Bool { isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            SpiderSceneView(width: width, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                            event: event, reduceMotion: reduceMotion)
        }
        .task(id: animates) {
            event = nil
            guard animates else { return }
            defer { event = nil }
            var firstVisit = true
            do {
                while !Task.isCancelled {
                    let delay = firstVisit ? Double.random(in: 2...5) : Double.random(in: 6...14)
                    try await Task.sleep(for: .seconds(delay))
                    try Task.checkCancellation()
                    let visit = SpiderDropEvent.random(start: Date.timeIntervalSinceReferenceDate)
                    event = visit
                    try await Task.sleep(for: .seconds(visit.duration))
                    event = nil
                    firstVisit = false
                }
            } catch is CancellationError {
                // Hiding the line, switching modes or Reduce Motion cancels this visit.
            } catch {
                event = nil
            }
        }
    }
}

/// Radial strands joined by inward-curving rings, like a hand-drawn spiderweb.
struct SpiderWebShape: Shape {
    var corner = false

    func path(in rect: CGRect) -> Path {
        let center = corner ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * (corner ? 1 : 0.5)
        let segments = corner ? 5 : 10
        let sweep = corner ? Double.pi / 2 : Double.pi * 2
        let start = corner ? 0 : -Double.pi / 2
        func point(_ index: Int, ring: CGFloat) -> CGPoint {
            let angle = start + Double(index) / Double(segments) * sweep
            let variation: CGFloat = corner ? 1 : (index % 2 == 0 ? 1 : 0.92)
            return CGPoint(x: center.x + cos(angle) * radius * ring * variation,
                           y: center.y + sin(angle) * radius * ring * variation)
        }
        var path = Path()
        for index in 0..<(corner ? segments + 1 : segments) {
            path.move(to: center)
            path.addLine(to: point(index, ring: 1))
        }
        for ring: CGFloat in [0.25, 0.5, 0.75, 1] {
            path.move(to: point(0, ring: ring))
            for index in 0..<segments {
                let a = point(index, ring: ring)
                let b = point(index + 1, ring: ring)
                let control = CGPoint(x: center.x + ((a.x + b.x) / 2 - center.x) * 0.82,
                                      y: center.y + ((a.y + b.y) / 2 - center.y) * 0.82)
                path.addQuadCurve(to: b, control: control)
            }
        }
        return path
    }
}

private struct SpiderWebMark: View {
    var corner = false

    var body: some View {
        ZStack {
            SpiderWebShape(corner: corner)
                .stroke(Color(red: 0.10, green: 0.17, blue: 0.28).opacity(0.38),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            SpiderWebShape(corner: corner)
                .stroke(LinearGradient(colors: [.white, Color(red: 0.68, green: 0.84, blue: 1).opacity(0.8)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct SpiderWebDecorations: View {
    let width: CGFloat

    var body: some View {
        let cornerSize = min(64, max(0, width) * 0.08)
        ZStack(alignment: .topLeading) {
            SpiderWebMark(corner: true)
                .frame(width: cornerSize, height: cornerSize)
                .position(x: cornerSize / 2, y: cornerSize / 2)
            SpiderWebMark(corner: true)
                .frame(width: cornerSize, height: cornerSize)
                .scaleEffect(x: -1, y: 1)
                .position(x: width - cornerSize / 2, y: cornerSize / 2)
            if width >= 700 {
                ForEach([0.075, 0.925], id: \.self) { fraction in
                    let x = width * fraction
                    let y = CaptureLineLayout.ropeY(x: x, width: width, style: .spiderMan)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: y - 3))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    SpiderWebMark()
                        .frame(width: 34, height: 34)
                        .rotationEffect(.degrees(fraction < 0.5 ? -12 : 12))
                        .position(x: x, y: y - 20)
                }
            }
        }
        .opacity(0.72)
    }
}

/// The same scene renderer is used by the animated overlay and deterministic documentation shots.
struct SpiderSceneView: View {
    let width: CGFloat
    let time: TimeInterval
    let event: SpiderDropEvent?
    var reduceMotion = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpiderWebDecorations(width: width)
            ForEach(0..<3, id: \.self) { index in
                let x = width * SpiderSceneLayout.centers[index]
                let ropeY = CaptureLineLayout.ropeY(x: x, width: width, style: .spiderMan)
                let size = SpiderSceneLayout.standingSize
                let direction: CGFloat = index == 2 ? -1 : 1
                let shot = SpiderSceneLayout.shot(time: time, index: index)
                let aim = reduceMotion ? 0 : shot.aim
                let pose = SpiderStandingPose(rawValue: index) ?? .singleHand
                let hands = pose.webHands(aim: aim)
                if !reduceMotion && shot.opacity > 0 {
                    ForEach(hands.indices, id: \.self) { handIndex in
                        let wrist = hands[handIndex]
                        let hand = CGPoint(x: x + direction * (wrist.x - 50) * size.width / 100,
                                           y: ropeY - size.height + wrist.y * size.height / 140)
                        let firingDirection = direction * (pose == .crouched && handIndex == 0 ? -1 : 1)
                        let length: CGFloat = pose == .upward ? 55 : 105
                        let rise: CGFloat = pose == .upward ? 48 : (pose == .crouched ? 18 : 26)
                        let tip = CGPoint(x: hand.x + firingDirection * min(length, width * 0.11) * shot.reach,
                                          y: hand.y - min(rise, max(0, hand.y - 15)) * shot.reach)
                        Path { path in
                            path.move(to: hand)
                            path.addLine(to: tip)
                            for spread: CGFloat in [-3, 3] {
                                path.move(to: hand)
                                path.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y + spread),
                                                  control: CGPoint(x: (hand.x + tip.x) / 2, y: (hand.y + tip.y) / 2 + spread))
                            }
                        }
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .shadow(color: Color(red: 0.12, green: 0.21, blue: 0.35), radius: 0.6)
                        .opacity(shot.opacity)
                        let bloom = SpiderSceneLayout.smooth((shot.reach - 0.65) / 0.35)
                        SpiderWebMark()
                            .frame(width: 23, height: 23)
                            .scaleEffect(0.3 + bloom * 0.7)
                            .rotationEffect(.degrees(firingDirection * 12))
                            .opacity(shot.opacity * bloom)
                            .position(x: tip.x, y: tip.y)
                    }
                }
                SpiderManMascot(isHanging: false, stance: index, aim: aim)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: direction, y: 1)
                    .position(x: x, y: ropeY - size.height / 2)
            }
            if !reduceMotion, let event, let pose = SpiderSceneLayout.drop(time: time, width: width, event: event) {
                if pose.attachment.y > 0 {
                    Path { path in
                        path.move(to: pose.anchor)
                        path.addLine(to: pose.attachment)
                    }
                    .stroke(Color(red: 0.16, green: 0.23, blue: 0.36).opacity(0.6), lineWidth: 3)
                    Path { path in
                        path.move(to: pose.anchor)
                        path.addLine(to: pose.attachment)
                    }
                    .stroke(Color.white.opacity(0.96), lineWidth: 1.2)
                }
                SpiderManMascot()
                    .frame(width: SpiderSceneLayout.dropSize.width, height: SpiderSceneLayout.dropSize.height)
                    .rotationEffect(.degrees(pose.angle), anchor: .top)
                    .position(x: pose.attachment.x, y: pose.attachment.y + SpiderSceneLayout.dropSize.height / 2)
            }
        }
        .frame(width: width, height: CaptureLineLayout.panelHeight, alignment: .topLeading)
        .clipped()
    }
}

/// A code-drawn mascot keeps the small mask, eyes and web pattern sharp at any display scale.
struct SpiderManMascot: View {
    var isHanging = true
    var stance = 0
    var aim: Double = 0

    var body: some View {
        Canvas { context, size in
            if isHanging {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: size.width / 100, y: -size.height / 140)
            } else {
                context.scaleBy(x: size.width / 100, y: size.height / 140)
            }
            let ink = Color(red: 0.055, green: 0.085, blue: 0.15)
            let red = Color(red: 0.94, green: 0.16, blue: 0.24)
            let blue = Color(red: 0.12, green: 0.34, blue: 0.65)

            func stroke(_ points: [CGPoint], color: Color, width: CGFloat) {
                var path = Path()
                path.move(to: points[0])
                if points.count == 3 {
                    let bend = points[1]
                    let end = points[2]
                    path.addLine(to: CGPoint(x: bend.x * 0.8 + points[0].x * 0.2,
                                            y: bend.y * 0.8 + points[0].y * 0.2))
                    path.addQuadCurve(to: CGPoint(x: bend.x * 0.8 + end.x * 0.2,
                                                 y: bend.y * 0.8 + end.y * 0.2), control: bend)
                    path.addLine(to: end)
                } else {
                    path.addLines(points)
                }
                let bounds = path.boundingRect.insetBy(dx: -width / 2, dy: -width / 2)
                let light = color == red ? Color(red: 1, green: 0.4, blue: 0.42) : Color(red: 0.3, green: 0.61, blue: 0.89)
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width + 3, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .linearGradient(Gradient(colors: [light, color, color.opacity(0.85)]),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            if isHanging {
                stroke([CGPoint(x: 40, y: 96), CGPoint(x: 30, y: 116), CGPoint(x: 43, y: 130)], color: blue, width: 12)
                stroke([CGPoint(x: 60, y: 96), CGPoint(x: 70, y: 116), CGPoint(x: 57, y: 130)], color: blue, width: 12)
                stroke([CGPoint(x: 40, y: 126), CGPoint(x: 47, y: 133)], color: red, width: 10)
                stroke([CGPoint(x: 60, y: 126), CGPoint(x: 53, y: 133)], color: red, width: 10)
            } else {
                let pose = SpiderStandingPose(rawValue: stance) ?? .singleHand
                switch pose {
                case .singleHand:
                    stroke([CGPoint(x: 40, y: 96), CGPoint(x: 31, y: 116), CGPoint(x: 31, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 60, y: 96), CGPoint(x: 69, y: 116), CGPoint(x: 69, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 31, y: 128), CGPoint(x: 24, y: 134)], color: red, width: 10)
                    stroke([CGPoint(x: 69, y: 128), CGPoint(x: 76, y: 134)], color: red, width: 10)
                case .crouched:
                    stroke([CGPoint(x: 42, y: 112), CGPoint(x: 17, y: 115), CGPoint(x: 25, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 58, y: 112), CGPoint(x: 83, y: 115), CGPoint(x: 75, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 25, y: 130), CGPoint(x: 18, y: 134)], color: red, width: 10)
                    stroke([CGPoint(x: 75, y: 130), CGPoint(x: 82, y: 134)], color: red, width: 10)
                case .upward:
                    stroke([CGPoint(x: 40, y: 99).applying(pose.upperTransform), CGPoint(x: 32, y: 119), CGPoint(x: 20, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 60, y: 99).applying(pose.upperTransform), CGPoint(x: 77, y: 112), CGPoint(x: 72, y: 131)], color: blue, width: 12)
                    stroke([CGPoint(x: 23, y: 130), CGPoint(x: 14, y: 134)], color: red, width: 10)
                    stroke([CGPoint(x: 72, y: 128), CGPoint(x: 80, y: 134)], color: red, width: 10)
                }
                context.concatenate(pose.upperTransform)
            }
            if isHanging {
                stroke([CGPoint(x: 34, y: 77), CGPoint(x: 17, y: 92), CGPoint(x: 12, y: 76)], color: red, width: 10)
                stroke([CGPoint(x: 66, y: 77), CGPoint(x: 83, y: 92), CGPoint(x: 88, y: 76)], color: red, width: 10)
            } else {
                let pose = SpiderStandingPose(rawValue: stance) ?? .singleHand
                let arms = pose.arms(aim: aim)
                for arm in arms { stroke(arm, color: red, width: 10) }
                if aim > 0.4 {
                    let firingArms = pose == .crouched ? [0, 1] : [1]
                    for index in firingArms {
                        let hand = arms[index][2]
                        let direction: CGFloat = index == 0 ? -1 : 1
                        let first = pose == .upward ? CGPoint(x: hand.x - 2, y: hand.y - 9)
                            : CGPoint(x: hand.x + direction * 6, y: hand.y - 8)
                        let second = pose == .upward ? CGPoint(x: hand.x + 4, y: hand.y - 8)
                            : CGPoint(x: hand.x + direction * 8, y: hand.y - 1)
                        stroke([hand, first], color: red, width: 2)
                        stroke([hand, second], color: red, width: 2)
                    }
                }
            }

            // A tapered suit and broad shoulders keep the silhouette readable at 44 pt.
            var torso = Path()
            torso.move(to: CGPoint(x: 34, y: 65))
            torso.addCurve(to: CGPoint(x: 66, y: 65), control1: CGPoint(x: 40, y: 60), control2: CGPoint(x: 60, y: 60))
            torso.addCurve(to: CGPoint(x: 64, y: 103), control1: CGPoint(x: 76, y: 76), control2: CGPoint(x: 63, y: 92))
            torso.addQuadCurve(to: CGPoint(x: 36, y: 103), control: CGPoint(x: 50, y: 114))
            torso.addCurve(to: CGPoint(x: 34, y: 65), control1: CGPoint(x: 37, y: 92), control2: CGPoint(x: 24, y: 76))
            torso.closeSubpath()
            context.fill(torso, with: .linearGradient(Gradient(colors: [Color(red: 0.27, green: 0.57, blue: 0.85), blue, ink]),
                startPoint: CGPoint(x: 30, y: 70), endPoint: CGPoint(x: 74, y: 115)))
            context.stroke(torso, with: .color(ink), lineWidth: 2.4)
            var chest = Path()
            chest.addLines([CGPoint(x: 34, y: 65), CGPoint(x: 66, y: 65), CGPoint(x: 62, y: 82),
                            CGPoint(x: 57, y: 94), CGPoint(x: 50, y: 101), CGPoint(x: 43, y: 94), CGPoint(x: 38, y: 82)])
            chest.closeSubpath()
            context.fill(chest, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.37, blue: 0.4), red, Color(red: 0.57, green: 0.04, blue: 0.16)]),
                startPoint: CGPoint(x: 37, y: 66), endPoint: CGPoint(x: 65, y: 100)))
            context.drawLayer { layer in
                layer.clip(to: chest)
                var seams = Path()
                for x: CGFloat in [39, 50, 61] {
                    seams.move(to: CGPoint(x: x, y: 65))
                    seams.addQuadCurve(to: CGPoint(x: 50 + (x - 50) * 0.5, y: 101), control: CGPoint(x: x, y: 83))
                }
                for y: CGFloat in [76, 86, 96] {
                    seams.move(to: CGPoint(x: 32, y: y - 4))
                    seams.addQuadCurve(to: CGPoint(x: 68, y: y - 4), control: CGPoint(x: 50, y: y + 5))
                }
                layer.stroke(seams, with: .color(ink.opacity(0.5)), lineWidth: 0.8)
            }
            // Eight-legged, silver-white chest emblem remains legible at native size.
            let emblemColor = Color(red: 0.88, green: 0.95, blue: 1)
            context.fill(Path(ellipseIn: CGRect(x: 47.6, y: 79, width: 4.8, height: 10)), with: .color(emblemColor))
            context.fill(Path(ellipseIn: CGRect(x: 48.3, y: 76.5, width: 3.4, height: 4)), with: .color(emblemColor))
            for side: CGFloat in [-1, 1] {
                for leg in 0..<4 {
                    var path = Path()
                    path.addLines([CGPoint(x: 50, y: 81 + CGFloat(leg)),
                                   CGPoint(x: 50 + side * 7, y: CGFloat(75 + leg * 5)),
                                   CGPoint(x: 50 + side * 9, y: CGFloat(72 + leg * 7))])
                    context.stroke(path, with: .color(emblemColor), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }

            // The mask is broad at the temples and softly tapered at the chin.
            var head = Path()
            head.move(to: CGPoint(x: 50, y: 2))
            head.addCurve(to: CGPoint(x: 88, y: 36), control1: CGPoint(x: 73, y: 1), control2: CGPoint(x: 89, y: 15))
            head.addCurve(to: CGPoint(x: 50, y: 76), control1: CGPoint(x: 88, y: 58), control2: CGPoint(x: 70, y: 73))
            head.addCurve(to: CGPoint(x: 12, y: 36), control1: CGPoint(x: 30, y: 73), control2: CGPoint(x: 12, y: 58))
            head.addCurve(to: CGPoint(x: 50, y: 2), control1: CGPoint(x: 11, y: 15), control2: CGPoint(x: 27, y: 1))
            head.closeSubpath()
            context.fill(head, with: .radialGradient(Gradient(stops: [
                .init(color: Color(red: 1, green: 0.48, blue: 0.43), location: 0),
                .init(color: red, location: 0.5),
                .init(color: Color(red: 0.64, green: 0.035, blue: 0.17), location: 0.88),
                .init(color: Color(red: 0.32, green: 0.035, blue: 0.14), location: 1)]),
                center: CGPoint(x: 32, y: 18), startRadius: 0, endRadius: 76))
            context.drawLayer { layer in
                layer.clip(to: head)
                // Curved web cells follow the volume of the mask, away from the eyes.
                let center = CGPoint(x: 50, y: 43)
                let ends = [CGPoint(x: 50, y: -7), CGPoint(x: 84, y: 0), CGPoint(x: 99, y: 32),
                            CGPoint(x: 89, y: 68), CGPoint(x: 50, y: 85), CGPoint(x: 11, y: 68),
                            CGPoint(x: 1, y: 32), CGPoint(x: 16, y: 0)]
                func point(_ index: Int, _ ring: CGFloat) -> CGPoint {
                    let end = ends[index % ends.count]
                    return CGPoint(x: center.x + (end.x - center.x) * ring,
                                   y: center.y + (end.y - center.y) * ring)
                }
                var web = Path()
                for end in ends {
                    web.move(to: center)
                    web.addLine(to: end)
                }
                for ring: CGFloat in [0.32, 0.59, 0.86, 1.13] {
                    web.move(to: point(0, ring))
                    for index in ends.indices {
                        let a = point(index, ring), b = point(index + 1, ring)
                        web.addQuadCurve(to: b, control: CGPoint(x: center.x + ((a.x + b.x) / 2 - center.x) * 0.83,
                                                                y: center.y + ((a.y + b.y) / 2 - center.y) * 0.83))
                    }
                }
                layer.stroke(web, with: .color(ink.opacity(0.65)), style: StrokeStyle(lineWidth: 0.95, lineCap: .round))
                var sheen = Path()
                sheen.move(to: CGPoint(x: 20, y: 25))
                sheen.addCurve(to: CGPoint(x: 60, y: 7), control1: CGPoint(x: 26, y: 9), control2: CGPoint(x: 44, y: 4))
                layer.stroke(sheen, with: .linearGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0)]),
                    startPoint: CGPoint(x: 24, y: 10), endPoint: CGPoint(x: 62, y: 16)),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                var rim = Path()
                rim.move(to: CGPoint(x: 83, y: 30))
                rim.addQuadCurve(to: CGPoint(x: 64, y: 67), control: CGPoint(x: 88, y: 52))
                layer.stroke(rim, with: .color(Color(red: 0.66, green: 0.73, blue: 1).opacity(0.45)),
                             style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            context.stroke(head, with: .color(ink), lineWidth: 2.6)
            for mirrored in [false, true] {
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mirrored ? 100 - x : x, y: y) }
                var eye = Path()
                eye.move(to: p(20, 28))
                eye.addCurve(to: p(46, 42), control1: p(29, 31), control2: p(39, 36))
                eye.addCurve(to: p(35, 58), control1: p(47, 52), control2: p(43, 59))
                eye.addCurve(to: p(20, 28), control1: p(23, 58), control2: p(20, 44))
                eye.closeSubpath()
                context.fill(eye, with: .linearGradient(Gradient(colors: [.white, Color(red: 0.91, green: 0.98, blue: 1),
                    Color(red: 0.47, green: 0.73, blue: 0.86)]), startPoint: p(30, 34), endPoint: p(40, 61)))
                context.stroke(eye, with: .color(ink), style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
                var reflection = Path()
                reflection.move(to: p(24, 36))
                reflection.addQuadCurve(to: p(33, 53), control: p(24, 48))
                context.stroke(reflection, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}

struct CaptureLineWebClip: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.95)).frame(width: 3, height: 26)
                .shadow(color: .black.opacity(0.5), radius: 1)
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.43, blue: 0.43),
                                                  Color(red: 0.91, green: 0.12, blue: 0.22),
                                                  Color(red: 0.52, green: 0.04, blue: 0.17)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 17, height: 17)
                .overlay(Circle().stroke(Color(red: 0.08, green: 0.13, blue: 0.24), lineWidth: 0.8))
                .overlay(Circle().trim(from: 0.55, to: 0.78).stroke(.white.opacity(0.6), lineWidth: 0.7).padding(1.7))
            Canvas { context, size in
                let ink = Color(red: 0.08, green: 0.13, blue: 0.24)
                context.fill(Path(ellipseIn: CGRect(x: 4, y: 4, width: 4, height: 6)), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: 4.5, y: 2.5, width: 3, height: 3)), with: .color(ink))
                for side: CGFloat in [-1, 1] {
                    for leg in 0..<4 {
                        var path = Path()
                        path.addLines([CGPoint(x: 6, y: 6), CGPoint(x: 6 + side * 3, y: CGFloat(2 + leg * 3)),
                                       CGPoint(x: 6 + side * 5, y: CGFloat(1 + leg * 3))])
                        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    }
                }
            }
            .frame(width: 12, height: 13)
        }
        .frame(width: 17, height: 26)
        .allowsHitTesting(false)
    }
}
