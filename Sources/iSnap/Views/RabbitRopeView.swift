import SwiftUI

/// Independent cutouts keep their size as the rope stretches across displays.
struct RabbitRopeArtwork: View {
    let width: CGFloat
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let centers: [CGFloat] = [0.16, 0.48, 0.84]
    private let images = ["CaptureLineRabbitCream", "CaptureLineRabbitGray", "CaptureLineRabbitBrown"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { index in
                    let x = width * centers[index]
                    // The lop-eared gray sprite has more transparent space above its head.
                    let size: CGFloat = index == 1 ? 104 : 88
                    let offset = size * (index == 1 ? 0.28 : 0.39)
                    let sway = reduceMotion ? 0 : sin(time * 1.4 + Double(index) * 1.8)
                    Image(images[index])
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(sway * 1.2), anchor: .bottom)
                        .position(x: x, y: CaptureLineLayout.ropeY(x: x, width: width, style: .rabbits) - offset + sway)
                }
            }
        }
    }
}

/// The carrot follows the same smooth out-and-back path slightly ahead of the rabbit.
/// Both slow down at the ends; the carrot lifts out of reach during each turn.
enum RabbitChaseLayout {
    static let cycle: TimeInterval = 48
    static let lead: TimeInterval = 0.9

    struct Pose {
        let rabbitX: CGFloat
        let carrotX: CGFloat
        let headingRight: Bool
        let hop: CGFloat
        let carrotLift: CGFloat
    }

    static func pose(time: TimeInterval, width: CGFloat) -> Pose {
        let width = max(0, width)
        let inset = min(28, width / 2)
        let travel = max(0, width - inset * 2)
        let phase = time.truncatingRemainder(dividingBy: cycle) / cycle * 2 * .pi
        let carrotPhase = phase + lead / cycle * 2 * .pi
        let rabbitX = inset + travel * CGFloat((1 - cos(phase)) / 2)
        let carrotX = inset + travel * CGFloat((1 - cos(carrotPhase)) / 2)
        return Pose(
            rabbitX: rabbitX,
            carrotX: carrotX,
            headingRight: carrotX >= rabbitX,
            hop: CGFloat(abs(sin(time * .pi * 1.6))) * 5,
            carrotLift: 18 * CGFloat(pow(abs(cos(carrotPhase)), 12))
        )
    }
}

struct RunningRabbitView: View {
    let width: CGFloat
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || reduceMotion)) { context in
            let time = reduceMotion ? RabbitChaseLayout.cycle / 4 : context.date.timeIntervalSinceReferenceDate
            let pose = RabbitChaseLayout.pose(time: time, width: width)
            let hop = reduceMotion ? 0 : pose.hop
            let rabbitY = CaptureLineLayout.ropeY(x: pose.rabbitX, width: width, style: .rabbits)
            let carrotY = CaptureLineLayout.ropeY(x: pose.carrotX, width: width, style: .rabbits)
            ZStack(alignment: .topLeading) {
                Image("RunningRabbit")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 38)
                    .scaleEffect(x: pose.headingRight ? 1 : -1, y: 1 - hop * 0.008, anchor: .bottom)
                    .rotationEffect(.degrees(Double(hop) * (pose.headingRight ? -0.7 : 0.7)))
                    .position(x: pose.rabbitX, y: rabbitY - 15 - hop)

                CaptureLineCarrot()
                    .frame(width: 16, height: 27)
                    .rotationEffect(.degrees(pose.headingRight ? 38 : -38))
                    .position(x: pose.carrotX, y: carrotY - 23 - pose.carrotLift - hop * 0.4)
            }
        }
    }
}

/// A tiny vector carrot stays crisp on both the moving lure and the photo clips.
struct CaptureLineCarrot: View {
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: size.width * x, y: size.height * y)
            }
            var leaves = Path()
            leaves.move(to: point(0.5, 0.32))
            leaves.addQuadCurve(to: point(0.17, 0.05), control: point(0.08, 0.16))
            leaves.move(to: point(0.5, 0.32))
            leaves.addLine(to: point(0.53, 0.04))
            leaves.move(to: point(0.5, 0.32))
            leaves.addQuadCurve(to: point(0.87, 0.08), control: point(0.92, 0.24))
            context.stroke(leaves, with: .color(Color(red: 0.40, green: 0.59, blue: 0.25)),
                           style: StrokeStyle(lineWidth: size.width * 0.15, lineCap: .round))
            var carrot = Path()
            carrot.move(to: point(0.23, 0.30))
            carrot.addQuadCurve(to: point(0.79, 0.32), control: point(0.52, 0.17))
            carrot.addQuadCurve(to: point(0.43, 0.95), control: point(0.80, 0.65))
            carrot.addQuadCurve(to: point(0.23, 0.30), control: point(0.15, 0.63))
            context.fill(carrot, with: .color(Color(red: 1, green: 0.63, blue: 0.29)))
            context.stroke(carrot, with: .color(Color(red: 0.47, green: 0.29, blue: 0.19)),
                           style: StrokeStyle(lineWidth: size.width * 0.07, lineJoin: .round))
            var ridges = Path()
            ridges.move(to: point(0.27, 0.45))
            ridges.addLine(to: point(0.47, 0.48))
            ridges.move(to: point(0.57, 0.63))
            ridges.addLine(to: point(0.68, 0.61))
            context.stroke(ridges, with: .color(Color(red: 0.78, green: 0.39, blue: 0.17)),
                           style: StrokeStyle(lineWidth: size.width * 0.06, lineCap: .round))
        }
    }
}
