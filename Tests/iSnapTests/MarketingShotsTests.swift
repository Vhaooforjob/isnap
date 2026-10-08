import AppKit
import SwiftUI
import XCTest
@testable import iSnap

/// Renders iSnap's real views with demo data for the README, the user
/// guide, and the introduction video. Skipped unless asked for:
///
///     ISNAP_SHOTS_DIR=/tmp/shots ISNAP_DEMO_DIR=brag-output/work/demo \
///       swift test --filter MarketingShotsTests
///
/// ISNAP_DEMO_DIR holds the screenshots shown inside iSnap (dash.png,
/// chart.png, board.png, employees.png, calendar.png). Nothing here touches
/// the user's settings, Library, Keychain, or widget.
@MainActor
final class MarketingShotsTests: XCTestCase {
    private var out: URL!
    private var demo: URL!
    private var sandbox: URL!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["ISNAP_SHOTS_DIR"], let demoPath = env["ISNAP_DEMO_DIR"] else {
            throw XCTSkip("Set ISNAP_SHOTS_DIR and ISNAP_DEMO_DIR to render documentation shots")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true)
        demo = URL(fileURLWithPath: demoPath, isDirectory: true)
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("iSnapShots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // Offscreen drawing follows the app appearance, not the window's.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() async throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    func testRenderDocumentationShots() async throws {
        let model = try makeModel()
        let image = try XCTUnwrap(NSImage(contentsOf: demo.appendingPathComponent("dash.png")))

        // Editor: the plain capture first, then annotated and beautified.
        model.document.load(CaptureResult(image: image, sourceName: "iSnap-Capture-20261008-091542.png"))
        model.document.canvas.showBackground = false
        try await shot(ContentView().environmentObject(model), "editor-plain", size: CGSize(width: 1440, height: 900))

        let size = model.document.imagePixelSize
        for annotation in demoAnnotations(in: size) { model.document.add(annotation) }
        model.document.selectedAnnotationID = nil
        model.document.canvas = beautifiedCanvas()
        model.settings.value.canvas = model.document.canvas
        try await shot(ContentView().environmentObject(model), "editor", size: CGSize(width: 1440, height: 900))

        // The final image, straight from the renderer that exports and copies.
        let rendered = try ExportRenderer.render(RenderRequest(
            image: image, annotations: model.document.annotations, canvas: model.document.canvas, includeBackground: true
        ))
        try write(rendered, "export")

        // Text extraction: real Vision output on the demo capture.
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let parsed = try await ScreenshotParserService().parse(cgImage)
        try await shot(
            ScreenshotParseView(text: .constant(parsed.text), sourceName: "iSnap-Capture-20261008-091542.png"),
            "ocr", size: CGSize(width: 640, height: 560)
        )

        // Library.
        model.section = .library
        await model.reloadLibrary()
        try await shot(ContentView().environmentObject(model), "library", size: CGSize(width: 1440, height: 900))
        model.section = .editor

        // Settings tabs.
        let locations = StorageService.locations(libraryFolder: model.settings.value.quickSave.folder, lineFolder: model.captureLine.ownedFolder)
        model.storageUsage = StorageService.measure(locations)
        for (tab, name) in [(SettingsView.Tab.captureLine, "settings-line"), (.storage, "settings-storage"),
                            (.startup, "settings-language"), (.hotkeys, "settings-hotkeys")] {
            model.settingsTab = tab
            try await shot(SettingsView(store: model.settings).environmentObject(model), name, size: CGSize(width: 760, height: 560))
        }

        // The Capture Line, on a transparent background.
        model.captureLine.isRevealed = true
        try await shot(CaptureLineView(line: model.captureLine), "line",
                       size: CGSize(width: 1600, height: CaptureLineLayout.panelHeight), transparent: true, settle: 3)
    }

    // MARK: Demo data

    private func makeModel() throws -> AppModel {
        let library = sandbox.appendingPathComponent("Library", isDirectory: true)
        let line = sandbox.appendingPathComponent("Line", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: line, withIntermediateDirectories: true)
        let names = ["dash", "chart", "board", "employees", "calendar"]
        for (index, name) in names.enumerated() {
            let target = library.appendingPathComponent("iSnap-Capture-20261008-09\(15 + index)42.png")
            try FileManager.default.copyItem(at: demo.appendingPathComponent("\(name).png"), to: target)
            // Newest first in the Library, in this order.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_791_440_000 - Double(index) * 600)], ofItemAtPath: target.path)
        }
        for (index, name) in ["chart", "board", "dash", "employees"].enumerated() {
            try FileManager.default.copyItem(
                at: demo.appendingPathComponent("\(name).png"),
                to: line.appendingPathComponent("Screenshot 2026-10-08 at 09.4\(index).1\(index).png"))
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "iSnapShots-\(UUID().uuidString)"))
        let store = SettingsStore(fileURL: sandbox.appendingPathComponent("settings.json"), userDefaults: defaults)
        store.value.quickSave.folder = library
        let captureLine = CaptureLine(ownedFolder: line, defaults: defaults)
        captureLine.playsSounds = false
        let files = try FileManager.default.contentsOfDirectory(at: line, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files { captureLine.hang(file, quietly: true) }
        return AppModel(settings: store, captureLine: captureLine, connectsServices: false)
    }

    /// Callouts on the demo dashboard, in source pixels (top-left origin).
    private func demoAnnotations(in size: CGSize) -> [Annotation] {
        let sx = size.width / 3200, sy = size.height / 2000
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }
        let cyan = RGBAColor(NSColor(srgbRed: 0, green: 0.78, blue: 1, alpha: 1))
        let magenta = RGBAColor(NSColor(srgbRed: 1, green: 0.22, blue: 0.48, alpha: 1))

        var box = Annotation(type: .rectangle, frame: rect(2515, 1130, 640, 345))
        box.stroke = magenta
        box.strokeWidth = 12 * sx
        box.cornerRadius = 36 * sx

        var arrow = Annotation.make(
            type: .arrow, from: CGPoint(x: 2240 * sx, y: 880 * sy), to: CGPoint(x: 2600 * sx, y: 1110 * sy),
            style: AnnotationStyle(stroke: magenta, strokeWidth: 14 * sx)
        )
        arrow.curved = true
        arrow.curveOffset = CGPoint(x: 60 * sx, y: -90 * sy)

        var label = Annotation(type: .text, frame: rect(1640, 770, 860, 120))
        label.text = "Payroll is ready"
        label.stroke = magenta
        label.fontSize = 76 * sy
        label.fontStyle = .bold
        label.textAlignment = .center

        let markers = [(rect(470, 1010, 110, 110), 1), (rect(1730, 1010, 110, 110), 2), (rect(2400, 1010, 110, 110), 3)]
            .map { frame, number -> Annotation in
                var marker = Annotation(type: .number, frame: frame)
                marker.stroke = cyan
                marker.number = number
                return marker
            }

        var sticker = Annotation(type: .image, frame: rect(1500, 300, 190, 190))
        sticker.imageData = try? StickerRenderer.pngData(for: "🚀")
        sticker.rotation = -12
        return [box, arrow, label, sticker] + markers
    }

    private func beautifiedCanvas() -> CanvasConfiguration {
        var canvas = CanvasConfiguration()
        canvas.showBackground = true
        canvas.gradient = GradientPreset.presets.first { $0.name == "Aurora" } ?? canvas.gradient
        canvas.padding = 120
        canvas.cornerRadius = 28
        canvas.shadowSize = 46
        var watermark = WatermarkConfiguration()
        watermark.text = "iSnap"
        watermark.opacity = 0.55
        watermark.sizePercent = 14
        canvas.watermark = watermark
        return canvas
    }

    // MARK: Rendering

    /// Renders a view in a borderless light window at 2x and writes a PNG.
    private func shot<V: View>(_ view: V, _ name: String, size: CGSize, transparent: Bool = false, settle: Double = 1.2) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        host.display()

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
    }

    private func write(_ image: NSImage, _ name: String) throws {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try data.write(to: out.appendingPathComponent("\(name).png"))
    }
}
