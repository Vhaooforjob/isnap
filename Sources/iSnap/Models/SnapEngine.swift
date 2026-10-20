import Foundation

struct SnapGuide: Equatable {
    var vertical: Bool
    var position: CGFloat
    var label: String? = nil
}

struct SnapResult {
    var frame: CGRect
    var guides: [SnapGuide]
}

enum SnapEngine {
    /// Coordinates and tolerance are in source pixels, independent of canvas zoom.
    static func snap(_ frame: CGRect, peers: [CGRect], bounds: CGRect, tolerance: CGFloat, resizing: Bool = false) -> SnapResult {
        var result = frame
        var guides: [SnapGuide] = []
        for vertical in [true, false] {
            func marks(_ rect: CGRect) -> [CGFloat] {
                vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
            }
            let moving = resizing ? [marks(frame)[2]] : marks(frame)
            let targets = (peers + [bounds]).flatMap(marks)
            var candidates: [(CGFloat, CGFloat, String?)] = []
            for point in moving {
                candidates += targets.map { ($0 - point, $0, nil) }
            }
            let length = vertical ? frame.width : frame.height
            // Preserve equal gaps before, after, or between nearby objects on the other axis.
            let neighbors = peers.filter {
                vertical ? $0.maxY >= frame.minY && $0.minY <= frame.maxY : $0.maxX >= frame.minX && $0.minX <= frame.maxX
            }.sorted { marks($0)[0] < marks($1)[0] }
            if !resizing, neighbors.count > 1 {
                for pair in zip(neighbors, neighbors.dropFirst()) {
                    let a = marks(pair.0), b = marks(pair.1), gap = marks(pair.1)[0] - marks(pair.0)[2]
                    if gap >= 0 {
                        let label = String(localized: "Gap \(Int(gap.rounded())) px")
                        candidates += [(b[2] + gap - marks(frame)[0], b[2] + gap, label),
                                       (a[0] - gap - marks(frame)[2], a[0] - gap, label)]
                        if gap >= length {
                            let center = (a[2] + b[0]) / 2
                            candidates.append((center - marks(frame)[1], center, String(localized: "Equal spacing")))
                        }
                    }
                }
            }
            var best: (CGFloat, CGFloat, String?)?
            for (delta, target, label) in candidates {
                if abs(delta) <= tolerance, best == nil || abs(delta) < abs(best!.0) {
                    best = (delta, target, label)
                }
            }
            if resizing {
                let current = vertical ? frame.width : frame.height
                for peer in peers {
                    let size = vertical ? peer.width : peer.height
                    let delta = size - current
                    if abs(delta) <= tolerance, best == nil || abs(delta) < abs(best!.0) {
                        best = (delta, marks(frame)[0] + size, String(localized: "Size \(Int(size.rounded())) px"))
                    }
                }
            }
            if let (delta, position, label) = best {
                if resizing {
                    if vertical { result.size.width = max(1, result.width + delta) }
                    else { result.size.height = max(1, result.height + delta) }
                } else if vertical { result.origin.x += delta } else { result.origin.y += delta }
                guides.append(SnapGuide(vertical: vertical, position: position, label: label))
            }
        }
        return SnapResult(frame: result, guides: guides)
    }
}
