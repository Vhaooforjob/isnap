import AppKit
import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case fullScreen
    case region
    case window

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fullScreen: "Full Screen"
        case .region: "Region"
        case .window: "Window"
        }
    }
    var symbol: String {
        switch self {
        case .fullScreen: "rectangle.on.rectangle"
        case .region: "viewfinder"
        case .window: "macwindow"
        }
    }
}

enum EditorTool: String, CaseIterable, Identifiable, Codable {
    case select, crop, rectangle, ellipse, arrow, line, text, spotlight, number, image

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .crop: "crop"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .spotlight: "lightbulb"
        case .number: "number.circle"
        case .image: "photo.on.rectangle"
        }
    }
}

enum WatermarkContentKind: String, CaseIterable, Identifiable, Codable {
    case text, image
    var id: String { rawValue }
}

enum WatermarkPlacement: String, CaseIterable, Identifiable, Codable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight
    case tiled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .top: "Top"
        case .topRight: "Top Right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom Right"
        case .tiled: "Tile Entire Image"
        }
    }
}

enum CropAspectRatio: String, CaseIterable, Identifiable, Codable {
    case free, ratio16x9 = "16:9", ratio4x3 = "4:3", square = "1:1"
    case ratio9x16 = "9:16", ratio3x4 = "3:4"

    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .free: nil
        case .ratio16x9: 16 / 9
        case .ratio4x3: 4 / 3
        case .square: 1
        case .ratio9x16: 9 / 16
        case .ratio3x4: 3 / 4
        }
    }
}

enum OutputRatio: String, CaseIterable, Identifiable, Codable {
    case automatic = "Auto", square = "1:1", ratio4x3 = "4:3", ratio3x2 = "3:2"
    case ratio16x9 = "16:9", ratio5x3 = "5:3", ratio9x16 = "9:16"
    case ratio3x4 = "3:4", ratio2x3 = "2:3"

    var id: String { rawValue }
    var value: CGFloat? {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }
}

enum BorderPosition: String, CaseIterable, Identifiable, Codable {
    case outside, center, inside
    var id: String { rawValue }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum FilenamePattern: String, CaseIterable, Identifiable, Codable {
    case timestamp, date, increment
    var id: String { rawValue }
}

struct CaptureResult: Identifiable {
    let id = UUID()
    let image: NSImage
    let sourceName: String
}

struct CapturableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let frame: CGRect
    let thumbnail: NSImage?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let modifiedAt: Date
    let dimensions: CGSize
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct StickerPreset: Identifiable, Hashable {
    let emoji: String
    let name: String

    var id: String { emoji }

    static let all: [StickerPreset] = [
        .init(emoji: "😀", name: "Smile"),
        .init(emoji: "😂", name: "Laugh"),
        .init(emoji: "😍", name: "Love"),
        .init(emoji: "😎", name: "Cool"),
        .init(emoji: "🤔", name: "Thinking"),
        .init(emoji: "😱", name: "Surprised"),
        .init(emoji: "🥳", name: "Celebrate"),
        .init(emoji: "🤩", name: "Starstruck"),
        .init(emoji: "👍", name: "Thumbs Up"),
        .init(emoji: "👎", name: "Thumbs Down"),
        .init(emoji: "👏", name: "Clap"),
        .init(emoji: "🙏", name: "Thanks"),
        .init(emoji: "💪", name: "Strong"),
        .init(emoji: "👀", name: "Look"),
        .init(emoji: "❤️", name: "Heart"),
        .init(emoji: "🔥", name: "Fire"),
        .init(emoji: "✨", name: "Sparkles"),
        .init(emoji: "🎉", name: "Party"),
        .init(emoji: "💯", name: "One Hundred"),
        .init(emoji: "✅", name: "Done"),
        .init(emoji: "❌", name: "Wrong"),
        .init(emoji: "⚠️", name: "Warning"),
        .init(emoji: "💡", name: "Idea"),
        .init(emoji: "📌", name: "Pin"),
        .init(emoji: "🚀", name: "Launch"),
        .init(emoji: "🎯", name: "Target"),
        .init(emoji: "⭐️", name: "Star"),
        .init(emoji: "👑", name: "Crown"),
        .init(emoji: "🐞", name: "Bug"),
        .init(emoji: "🔒", name: "Locked")
    ]
}

struct RGBAColor: Codable, Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(_ color: NSColor) {
        let value = color.usingColorSpace(.sRGB) ?? color
        red = value.redComponent
        green = value.greenComponent
        blue = value.blueComponent
        alpha = value.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    static let red = RGBAColor(.systemRed)
    static let clear = RGBAColor(.clear)
    static let white = RGBAColor(.white)
}

struct GradientPreset: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let start: RGBAColor
    let end: RGBAColor

    static let presets: [GradientPreset] = [
        .init(name: "Sunset", start: .init(NSColor(hex: 0xF093FB)), end: .init(NSColor(hex: 0xF5576C))),
        .init(name: "Ocean", start: .init(NSColor(hex: 0x667EEA)), end: .init(NSColor(hex: 0x764BA2))),
        .init(name: "Forest", start: .init(NSColor(hex: 0x11998E)), end: .init(NSColor(hex: 0x38EF7D))),
        .init(name: "Fire", start: .init(NSColor(hex: 0xF12711)), end: .init(NSColor(hex: 0xF5AF19))),
        .init(name: "Cool Blue", start: .init(NSColor(hex: 0x2193B0)), end: .init(NSColor(hex: 0x6DD5ED))),
        .init(name: "Lavender", start: .init(NSColor(hex: 0xC471F5)), end: .init(NSColor(hex: 0xFA71CD))),
        .init(name: "Aqua", start: .init(NSColor(hex: 0x13547A)), end: .init(NSColor(hex: 0x80D0C7))),
        .init(name: "Grape", start: .init(NSColor(hex: 0x5F2C82)), end: .init(NSColor(hex: 0x49A09D))),
        .init(name: "Peach", start: .init(NSColor(hex: 0xFFECD2)), end: .init(NSColor(hex: 0xFCB69F))),
        .init(name: "Sky", start: .init(NSColor(hex: 0xA8EDEA)), end: .init(NSColor(hex: 0xFED6E3))),
        .init(name: "Warm", start: .init(NSColor(hex: 0xFF9A9E)), end: .init(NSColor(hex: 0xFECFEF))),
        .init(name: "Mint", start: .init(NSColor(hex: 0xD4FC79)), end: .init(NSColor(hex: 0x96E6A1))),
        .init(name: "Midnight", start: .init(NSColor(hex: 0x0F0C29)), end: .init(NSColor(hex: 0x24243E))),
        .init(name: "Carbon", start: .init(NSColor(hex: 0x1A1A2E)), end: .init(NSColor(hex: 0x16213E))),
        .init(name: "Deep Space", start: .init(NSColor(hex: 0x000428)), end: .init(NSColor(hex: 0x004E92))),
        .init(name: "Noir", start: .init(NSColor(hex: 0x232526)), end: .init(NSColor(hex: 0x414345))),
        .init(name: "Royal", start: .init(NSColor(hex: 0x141E30)), end: .init(NSColor(hex: 0x243B55))),
        .init(name: "Rose Gold", start: .init(NSColor(hex: 0xF4C4F3)), end: .init(NSColor(hex: 0xFC67FA))),
        .init(name: "Emerald", start: .init(NSColor(hex: 0x1D976C)), end: .init(NSColor(hex: 0x93F9B9))),
        .init(name: "Amethyst", start: .init(NSColor(hex: 0x9D50BB)), end: .init(NSColor(hex: 0x6E48AA))),
        .init(name: "Neon", start: .init(NSColor(hex: 0x00F260)), end: .init(NSColor(hex: 0x0575E6))),
        .init(name: "Aurora", start: .init(NSColor(hex: 0x00C6FB)), end: .init(NSColor(hex: 0x005BEA))),
        .init(name: "Candy", start: .init(NSColor(hex: 0xFF6A88)), end: .init(NSColor(hex: 0xFF99AC))),
        .init(name: "Clean", start: .init(NSColor(hex: 0xF5F7FA)), end: .init(NSColor(hex: 0xC3CFE2)))
    ]
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
