import AppKit

/// Geometry is stored as a polyline so preview, export, erasing and projects agree exactly.
enum StrokeGeometry {
    static func smooth(_ points: [CGPoint], tolerance: CGFloat = 0.7) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep: Set<Int> = [0, points.count - 1], stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var greatest = tolerance, index: Int?
            for i in (a + 1)..<b {
                let distance = segmentDistance(points[i], points[a], points[b])
                if distance > greatest { greatest = distance; index = i }
            }
            if let i = index { keep.insert(i); stack.append((a, i)); stack.append((i, b)) }
        }
        let reduced = keep.sorted().map { points[$0] }
        var result = [reduced[0]]
        for (a, b) in zip(reduced, reduced.dropFirst()) {
            result.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
            result.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
        }
        result.append(reduced.last!)
        return result
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / length : 0
        return hypot(p.x - a.x - dx * t.clamped(to: 0...1), p.y - a.y - dy * t.clamped(to: 0...1))
    }

    /// Split at exact segment/circle intersections, including sparse two-point strokes.
    static func erase(_ points: [CGPoint], center: CGPoint, radius: CGFloat) -> [[CGPoint]] {
        guard points.count > 1, radius > 0 else { return points.isEmpty ? [] : [points] }
        var pieces: [[CGPoint]] = [], current: [CGPoint] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, fx = a.x - center.x, fy = a.y - center.y
            let aa = dx * dx + dy * dy, bb = 2 * (fx * dx + fy * dy), cc = fx * fx + fy * fy - radius * radius
            var cuts: [CGFloat] = [0, 1]
            let d = bb * bb - 4 * aa * cc
            if aa > 0, d > 0 {
                cuts += [(-bb - sqrt(d)) / (2 * aa), (-bb + sqrt(d)) / (2 * aa)].filter { $0 > 0 && $0 < 1 }
            }
            cuts.sort()
            for (t0, t1) in zip(cuts, cuts.dropFirst()) {
                let m = (t0 + t1) / 2
                if hypot(fx + m * dx, fy + m * dy) >= radius {
                    let start = CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy)
                    if current.last != start { current.append(start) }
                    current.append(CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
                } else if !current.isEmpty { pieces.append(current); current = [] }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.filter { $0.count >= 2 }
    }

    static func worldPoints(_ item: Annotation) -> [CGPoint] {
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY), angle = item.rotation * .pi / 180
        return item.points.map {
            let x = item.frame.minX + $0.x - center.x, y = item.frame.minY + $0.y - center.y
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
    }
}

struct PixelSample: Equatable {
    let x: Int, y: Int, red: Int, green: Int, blue: Int, alpha: Int
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var description: String { "\(hex) · RGB(\(red), \(green), \(blue)) · (\(x), \(y)) px · α \(alpha)" }
    static func read(_ image: CGImage, at point: CGPoint) throws -> PixelSample {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw ExportError.invalidImage }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self), a = Int(bytes[3])
        func straight(_ channel: UInt8) -> Int { a == 0 ? 0 : min(255, Int(channel) * 255 / a) }
        return PixelSample(x: x, y: y, red: straight(bytes[0]), green: straight(bytes[1]), blue: straight(bytes[2]), alpha: a)
    }
}
