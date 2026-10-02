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
    var number: Int?

    enum FontStyle: String, CaseIterable, Identifiable, Codable {
        case regular, bold, italic, boldItalic
        var id: String { rawValue }
    }

    enum TextAlignment: String, CaseIterable, Identifiable, Codable {
        case left, center, right
        var id: String { rawValue }
    }

    var normalizedFrame: CGRect {
        CGRect(
            x: min(frame.minX, frame.maxX),
            y: min(frame.minY, frame.maxY),
            width: abs(frame.width),
            height: abs(frame.height)
        )
    }

    static func make(type: EditorTool, from start: CGPoint, to end: CGPoint, style: AnnotationStyle) -> Annotation {
        let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
        return Annotation(
            type: type,
            frame: rect,
            points: [.zero, CGPoint(x: rect.width, y: rect.height)],
            stroke: style.stroke,
            fill: style.fill,
            strokeWidth: style.strokeWidth,
            cornerRadius: style.cornerRadius,
            text: type == .text ? "Text" : "",
            fontSize: style.fontSize,
            fontStyle: style.fontStyle,
            curved: style.curvedArrow,
            dimOpacity: style.dimOpacity
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
}

struct CanvasConfiguration: Codable, Equatable {
    var padding: CGFloat = 40
    var cornerRadius: CGFloat = 12
    var shadowSize: CGFloat = 20
    var gradient = GradientPreset.presets[1]
    var backgroundImageURL: URL?
    var outputRatio = OutputRatio.automatic
    var showBackground = true
    var insetPercent: CGFloat = 0
    var autoBackground = true
    var insetColor = RGBAColor(.clear)
    var borderEnabled = false
    var borderWeight: CGFloat = 2
    var borderColor = RGBAColor(.black)
    var borderOpacity: CGFloat = 1
    var borderPosition = BorderPosition.center
}
