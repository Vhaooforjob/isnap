import AppKit
import AppIntents
import PDFKit
import XCTest
@testable import iSnap

final class UpgradeTests: XCTestCase {
    private func image(_ color: NSColor = .white, width: Int = 240, height: Int = 160) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var plain: CanvasConfiguration {
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0; return canvas
    }
    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    @MainActor func testLegacyWorkspaceAndCollectionPersistence() throws {
        let legacy = #"{"presets":[],"metadata":{},"captureDelay":0,"showsCursor":false}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(WorkspaceState.self, from: legacy)
        XCTAssertNil(state.collections); XCTAssertNil(state.savedFilters); XCTAssertNil(state.redactionRules)
        let root = try folder(), url = root.appendingPathComponent("workspace.json")
        try legacy.write(to: url)
        let features = WorkspaceFeatures(url: url)
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        let collection = LibraryCollection(name: "Project A")
        features.state.collections = [collection]
        features.setTags(["original"], for: [a])
        features.addTag("bug", to: [a, b]); features.addTag("bug", to: [a])
        features.setCollection(collection.id, for: [a, b], included: true)
        features.state.savedFilters = [SavedLibraryFilter(name: "Bugs", query: "bug", favoritesOnly: true,
            days: 7, collectionID: collection.id, sort: "name")]
        features.state.redactionRules = [RedactionRule(name: "Account", pattern: "ACME")]
        let restored = WorkspaceFeatures(url: url)
        XCTAssertEqual(restored.metadata(for: a).tags, ["bug", "original"])
        XCTAssertEqual(restored.metadata(for: b).collectionIDs, [collection.id])
        XCTAssertEqual(restored.state.savedFilters?.first?.collectionID, collection.id)
        XCTAssertEqual(restored.state.redactionRules?.first?.pattern, "ACME")
        restored.setCollection(collection.id, for: [b], included: false)
        XCTAssertEqual(restored.metadata(for: b).collectionIDs, [])
        restored.deleteCollection(collection.id)
        XCTAssertTrue(restored.state.savedFilters?.isEmpty == true)
        XCTAssertEqual(restored.metadata(for: a).collectionIDs, [])
        XCTAssertEqual(restored.metadata(for: a).tags, ["bug", "original"])
    }

    func testRedactionRulesLiteralRegexDisabledAndInvalid() async throws {
        let regions = ["PROJECT.a", "projectXa", "token=abc123", "hello", "person@example.com"].map {
            RecognizedRegion(text: $0, rect: CGRect(x: 0, y: 0, width: 100, height: 20))
        }
        var rules = [RedactionRule(name: "Literal", pattern: "project.a"),
                     RedactionRule(name: "Token", pattern: #"token=[a-z0-9]+"#, regularExpression: true)]
        let suggestions = try await RedactionRule.suggestions(in: regions, rules: rules)
        XCTAssertEqual(suggestions.map(\.text),
            ["PROJECT.a", "token=abc123", "person@example.com"])
        rules[1].enabled = false
        let remaining = try await RedactionRule.suggestions(in: regions, rules: rules)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertThrowsError(try RedactionRule(name: "Invalid", pattern: "[", regularExpression: true).expression())
    }

    @MainActor func testFreehandGeometryResizeUndoAndProjectRoundTrip() throws {
        let doc = EditorDocument()
        doc.load(CaptureResult(image: NSImage(cgImage: try image(), size: CGSize(width: 240, height: 160)), sourceName: "Drawing"))
        let stroke = Annotation.freehand([CGPoint(x: 80, y: 60), CGPoint(x: 20, y: 20), CGPoint(x: 50, y: 90)], style: AnnotationStyle())
        XCTAssertEqual(stroke.frame, CGRect(x: 20, y: 20, width: 60, height: 70))
        XCTAssertEqual(stroke.points.first, CGPoint(x: 60, y: 40))
        doc.add(stroke)
        doc.setFrame(CGRect(x: 30, y: 40, width: 120, height: 140), for: stroke.id)
        XCTAssertEqual(doc.annotations[0].points.first, CGPoint(x: 120, y: 80))
        doc.undo()
        XCTAssertEqual(doc.annotations[0].frame, stroke.frame)
        let project = try doc.project()
        let restored = EditorDocument(); try restored.loadProject(project)
        XCTAssertEqual(restored.annotations, [stroke])
        let rendered = try ExportRenderer.render(RenderRequest(image: doc.image!, annotations: [stroke], canvas: plain, includeBackground: false))
        let cg = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = try color(cg, x: 50, y: 40)
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
    }

    func testMagnifierSamplesMaskedPixelsEvenWhenMaskComesLater() throws {
        var lens = Annotation(type: .magnifier, frame: CGRect(x: 120, y: 60, width: 80, height: 80))
        lens.magnifierSource = CGRect(x: 20, y: 20, width: 40, height: 40)
        lens.magnification = 2
        let mask = Annotation(type: .redact, frame: CGRect(x: 10, y: 10, width: 60, height: 60))
        let source = NSImage(cgImage: try image(.red), size: CGSize(width: 240, height: 160))
        for limit: Int? in [nil, 120] {
            let rendered = try ExportRenderer.render(RenderRequest(image: source, annotations: [lens, mask], canvas: plain, includeBackground: false), maxPixelDimension: limit)
            let cg = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let scale = CGFloat(cg.width) / 240
            let pixel = try color(cg, x: Int(160 * scale), y: Int(100 * scale))
            XCTAssertLessThan(pixel.redComponent, 0.02)
            XCTAssertLessThan(pixel.greenComponent, 0.02)
            XCTAssertLessThan(pixel.blueComponent, 0.02)
        }
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(lens))
        XCTAssertEqual(decoded.magnifierSource, lens.magnifierSource)
    }

    func testComparisonIdenticalDifferenceAndUnequalSizeAlignment() throws {
        let a = try image(.red, width: 100, height: 60)
        let identical = try ImageComparisonService.compare(a, a)
        let pixel = try color(identical.difference, x: 50, y: 30)
        XCTAssertLessThan(pixel.redComponent + pixel.greenComponent + pixel.blueComponent, 0.01)
        let b = try image(.blue, width: 60, height: 100)
        let result = try ImageComparisonService.compare(a, b)
        XCTAssertEqual(result.size, CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(try color(result.before, x: 50, y: 20).redComponent, 0.9)
        XCTAssertGreaterThan(try color(result.after, x: 20, y: 20).blueComponent, 0.9)
        XCTAssertGreaterThan(try color(result.after, x: 80, y: 80).redComponent, 0.9) // White padding.
    }

    func testSearchablePDFTextPositionsAndInvisibleDrawing() throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        let text = "Xin chào Việt Nam"
        CompositionService.drawSearchableText([RecognizedRegion(text: text, rect: CGRect(x: 20, y: 30, width: 200, height: 25))],
            imageHeight: 300, offset: 0, in: context)
        context.endPDFPage(); context.closePDF()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        XCTAssertTrue(pdf.string?.contains(text) == true)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let selection = try XCTUnwrap(pdf.findString(text).first)
        let bounds = selection.bounds(for: page)
        XCTAssertEqual(bounds.minX, 20, accuracy: 2)
        XCTAssertEqual(bounds.maxY, 270, accuracy: 5)
        let preview = page.thumbnail(of: CGSize(width: 400, height: 300), for: .mediaBox)
        let cg = try XCTUnwrap(preview.cgImage(forProposedRect: nil, context: nil, hints: nil))
        for y in stride(from: 30, through: 55, by: 5) {
            XCTAssertGreaterThan(try color(cg, x: 60, y: y).redComponent, 0.95)
        }
    }

    func testSearchablePDFFromFlattenedMaskedImage() async throws {
        let root = try folder()
        let source = NSImage(cgImage: try image(width: 600, height: 200), size: CGSize(width: 600, height: 200))
        let visible = Annotation(type: .text, frame: CGRect(x: 20, y: 20, width: 500, height: 60), stroke: RGBAColor(.black), text: "VISIBLE DOCUMENT", fontSize: 32)
        let secret = Annotation(type: .text, frame: CGRect(x: 20, y: 100, width: 500, height: 60), stroke: RGBAColor(.black), text: "SECRET TOKEN", fontSize: 32)
        let mask = Annotation(type: .redact, frame: CGRect(x: 0, y: 90, width: 600, height: 110))
        let flattened = try ExportRenderer.render(RenderRequest(image: source, annotations: [visible, secret, mask], canvas: plain, includeBackground: false))
        let url = root.appendingPathComponent("masked.png")
        try ProjectStore.png(flattened).write(to: url)
        let pdf = try await CompositionService().pdf([CompositionPage(url: url, caption: "")], captions: false, searchable: true)
        let text = try XCTUnwrap(PDFDocument(data: pdf)?.string)
        XCTAssertTrue(text.contains("VISIBLE"))
        XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("TOKEN"))
    }

    func testAutomationExportResizeFormatsAndInvalidInput() async throws {
        let source = try XCTUnwrap(NSBitmapImageRep(cgImage: image(.red, width: 400, height: 200)).representation(using: .png, properties: [:]))
        let service = AutomationImageService()
        for format in [ShortcutImageFormat.png, .jpeg] {
            let data = try await service.export(source, canvas: plain, maxDimension: 100, format: format)
            let result = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(result.pixelsWide, 100); XCTAssertEqual(result.pixelsHigh, 50)
        }
        do { _ = try await service.export(source, canvas: plain, maxDimension: -1, format: .png); XCTFail("Invalid size accepted") }
        catch AutomationError.invalidSize { }
        do { _ = try await service.extract(Data("not an image".utf8)); XCTFail("Invalid image accepted") }
        catch ExportError.invalidImage { }
    }

    func testShortcutsExportActionReturnsAUsableFile() async throws {
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image(width: 300, height: 150)).representation(using: .png, properties: [:]))
        let intent = ExportScreenshotIntent()
        intent.image = IntentFile(data: data, filename: "example.png", type: .png)
        intent.maxDimension = 120
        intent.format = .png
        let result = try await intent.perform()
        let file = try XCTUnwrap(result.value)
        XCTAssertEqual(file.filename, "example-edited.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: file.data))
        XCTAssertEqual(bitmap.pixelsWide, 120)
        XCTAssertEqual(bitmap.pixelsHigh, 60)
    }

    @MainActor func testAutomaticCaptureStopsAtUnchangedContentAndCanBeCancelled() async throws {
        let first = try image()
        let controller = ScrollCaptureController()
        var captures = 0
        controller.begin(first: first, capture: { captures += 1; return first }, scroll: {}, presentsPanel: false, completion: { _ in })
        controller.settleDelay = 0.5
        controller.startAutomatic()
        for _ in 0..<40 {
            if !controller.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.automatic)
        XCTAssertEqual(controller.frames.count, 1)
        XCTAssertNil(controller.pending)
        XCTAssertEqual(captures, 2)
        controller.startAutomatic()
        controller.pauseAutomatic()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.frames.count, 1)
        controller.cancel()
        XCTAssertTrue(controller.frames.isEmpty)
    }

    @MainActor func testAutomaticCapturePausesForAnUncertainSeam() async throws {
        let first = try image(), next = try image(.black)
        let controller = ScrollCaptureController()
        controller.begin(first: first, capture: { next }, scroll: {}, presentsPanel: false, completion: { _ in })
        controller.settleDelay = 0.5
        controller.startAutomatic()
        for _ in 0..<40 {
            if !controller.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(controller.busy)
        XCTAssertNotNil(controller.pending)
        XCTAssertEqual(controller.frames.count, 1)
        controller.addPending()
        XCTAssertNil(controller.pending)
        XCTAssertEqual(controller.frames.count, 2)
        controller.cancel()
    }

    @MainActor func testAutomaticOverlapRefinesRetinaFrameAtExactPixel() async throws {
        let width = 96, height = 1800
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // Coherent rows remain identifiable after thumbnail sampling.
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(((y / 11 * 73 + (y / 23) * 31) ^ (x * 17)) % 256)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let original = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let first = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: width, height: 1200)))
        let next = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 537, width: width, height: 1200)))
        XCTAssertEqual(ScrollingStitcher.automaticOverlap(previous: first, next: next), 663)
        let controller = ScrollCaptureController()
        controller.begin(first: first, capture: { next }, scroll: {}, presentsPanel: false, completion: { _ in })
        controller.settleDelay = 0.5
        controller.startAutomatic()
        for _ in 0..<50 {
            if !controller.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.frames.count, 2)
        XCTAssertEqual(controller.overlaps, [663])
        XCTAssertNil(controller.pending)
        controller.cancel()
    }

    func testAutomaticScrollRejectsChangedAndAmbiguousContent() throws {
        let white = try image(), black = try image(.black)
        XCTAssertTrue(ScrollingStitcher.unchanged(white, white))
        XCTAssertFalse(ScrollingStitcher.unchanged(white, black))
        XCTAssertNil(ScrollingStitcher.estimateOverlap(previous: white, next: black))
        XCTAssertFalse(ScrollingStitcher.unchanged(white, try image(width: 241)))
    }
}
