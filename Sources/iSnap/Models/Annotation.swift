import AppKit
import Foundation

struct Annotation: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: EditorTool
    var frame: CGRect
    var points: [CGPoint] = []
    var stroke = RGBAColor.red
    var fill = RGBAColor.clear
    var strokeWidth: CGFloat = 4
    var cornerRadius: CGFloat = 0
    var rotation: CGFloat = 0
    var text: String = "Text"
    var fontSize: CGFloat = 32
    var fontStyle: FontStyle = .regular
    var textAlignment: TextAlignment = .left
    var curved = false
    var curveOffset = CGPoint.zero
    var dimOpacity: CGFloat = 0.7
    var markerStyle = MarkerStyle.number
    var number: Int?

    enum FontStyle: String, CaseIterable, Identifiable, Codable {
        case regular, bold, italic, boldItalic
        var id: String { rawValue }
    }

    enum TextAlignment: String, CaseIterable, Identifiable, Codable {
        case left, center, right
        var id: String { rawValue }
    }

    enum MarkerStyle: String, CaseIterable, Identifiable, Codable {
        case number
        case uppercaseLetter
        case lowercaseLetter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .number: "1, 2, 3"
            case .uppercaseLetter: "A, B, C"
            case .lowercaseLetter: "a, b, c"
            }
        }
    }

    var markerLabel: String {
        let value = max(1, number ?? 1)
        switch markerStyle {
        case .number:
            return String(value)
        case .uppercaseLetter:
            return Self.alphabeticLabel(for: value)
        case .lowercaseLetter:
            return Self.alphabeticLabel(for: value).lowercased()
        }
    }

    static func alphabeticLabel(for value: Int) -> String {
        var index = max(1, value)
        var characters: [Character] = []
        while index > 0 {
            index -= 1
            characters.append(Character(UnicodeScalar(65 + index % 26)!))
            index /= 26
        }
        return String(characters.reversed())
    }

    var normalizedFrame: CGRect {
        CGRect(
            x: min(frame.minX, frame.maxX),
            y: min(frame.minY, frame.maxY),
            width: abs(frame.width),
            height: abs(frame.height)
        )
    }

    var lineStartPoint: CGPoint {
        points.first.map { CGPoint(x: frame.origin.x + $0.x, y: frame.origin.y + $0.y) }
            ?? frame.origin
    }

    var lineEndPoint: CGPoint {
        points.last.map { CGPoint(x: frame.origin.x + $0.x, y: frame.origin.y + $0.y) }
            ?? CGPoint(x: frame.origin.x + frame.width, y: frame.origin.y + frame.height)
    }

    mutating func setLineEndpoints(start: CGPoint, end: CGPoint) {
        let bounds = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        frame = bounds
        points = [
            CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY),
            CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        ]
    }

    static func make(type: EditorTool, from start: CGPoint, to end: CGPoint, style: AnnotationStyle) -> Annotation {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let points: [CGPoint]
        if type == .line || type == .arrow {
            points = [
                CGPoint(x: start.x - rect.minX, y: start.y - rect.minY),
                CGPoint(x: end.x - rect.minX, y: end.y - rect.minY)
            ]
        } else {
            points = [.zero, CGPoint(x: rect.width, y: rect.height)]
        }
        return Annotation(
            type: type,
            frame: rect,
            points: points,
            stroke: style.stroke,
            fill: style.fill,
            strokeWidth: style.strokeWidth,
            cornerRadius: style.cornerRadius,
            text: type == .text ? "Text" : "",
            fontSize: style.fontSize,
            fontStyle: style.fontStyle,
            curved: style.curvedArrow,
            dimOpacity: style.dimOpacity,
            markerStyle: style.markerStyle
        )
    }
}

struct AnnotationStyle: Codable, Equatable {
    var stroke = RGBAColor.red
    var fill = RGBAColor.clear
    var strokeWidth: CGFloat = 4
    var cornerRadius: CGFloat = 0
    var fontSize: CGFloat = 32
    var fontStyle = Annotation.FontStyle.regular
    var curvedArrow = false
    var dimOpacity: CGFloat = 0.7
    var markerStyle = Annotation.MarkerStyle.number
}

struct CanvasConfiguration: Codable, Equatable {
    var padding: CGFloat = 40
    var cornerRadius: CGFloat = 12
    var shadowSize: CGFloat = 20
    var gradient = GradientPreset.presets[1]
    var backgroundImageURL: URL?
    var outputRatio = OutputRatio.automatic
    var showBackground = false
    var insetPercent: CGFloat = 0
    var autoBackground = true
    var insetColor = RGBAColor(.clear)
    var borderEnabled = false
    var borderWeight: CGFloat = 2
    var borderColor = RGBAColor(.black)
    var borderOpacity: CGFloat = 1
    var borderPosition = BorderPosition.center
}
