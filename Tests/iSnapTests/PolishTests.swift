import AppKit
import CoreImage
import PDFKit
import XCTest
@testable import iSnap

final class PolishTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isnap-polish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func image(width: Int = 200, height: Int = 120, draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx); return try XCTUnwrap(ctx.makeImage())
    }
    private func write(_ image: CGImage, _ url: URL) throws {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
    private func item(_ url: URL) -> iSnap.LibraryItem {
        LibraryItem(url: url, modifiedAt: Date(), dimensions: CGSize(width: 200, height: 120), fileIdentity: FileIdentity.read(url))
    }

    @MainActor func testFinderRenameMoveCopyReplacementAndBackup() throws {
        let root = try folder(), movedRoot = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png"), c = movedRoot.appendingPathComponent("c.png")
        try write(image(), a)
        let store = WorkspaceFeatures(url: root.appendingPathComponent("metadata.json"))
        store.reconcileLibrary([item(a)], in: root); store.setTags(["bug"], for: [a])
        let id = store.metadata(for: a).recordID
        try FileManager.default.moveItem(at: a, to: b)
        store.reconcileLibrary([item(b)], in: root)
        XCTAssertEqual(store.metadata(for: b).tags, ["bug"]); XCTAssertEqual(store.metadata(for: b).recordID, id)
        try FileManager.default.copyItem(at: b, to: a)
        store.reconcileLibrary([item(a), item(b)], in: root)
        XCTAssertTrue(store.metadata(for: a).tags.isEmpty); XCTAssertNotEqual(store.metadata(for: a).recordID, id)
        try FileManager.default.moveItem(at: b, to: c)
        store.reconcileLibrary([item(a)], in: root); store.reconcileLibrary([item(c)], in: movedRoot)
        XCTAssertEqual(store.metadata(for: c).tags, ["bug"])
        let backup = try store.exportLibraryMetadata()
        let restored = WorkspaceFeatures(url: root.appendingPathComponent("restored.json"))
        restored.reconcileLibrary([item(c)], in: movedRoot); try restored.importLibraryMetadata(backup)
        XCTAssertEqual(restored.metadata(for: c).tags, ["bug"])
        try FileManager.default.removeItem(at: c); try write(image(), c)
        restored.reconcileLibrary([item(c)], in: movedRoot)
        XCTAssertTrue(restored.metadata(for: c).tags.isEmpty)
        XCTAssertFalse(restored.state.detachedMetadata?.isEmpty ?? true)
        restored.relinkMetadata(from: c.standardizedFileURL.path, to: item(c))
        XCTAssertEqual(restored.metadata(for: c).tags, ["bug"])
    }

    @MainActor func testSwappedFilenamesRetainBothRecords() throws {
        let root = try folder(), a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png"), temp = root.appendingPathComponent("temp.png")
        try write(image(), a); try write(image(), b)
        let store = WorkspaceFeatures(url: root.appendingPathComponent("metadata.json"))
        store.reconcileLibrary([item(a), item(b)], in: root)
        store.setTags(["A"], for: [a]); store.setTags(["B"], for: [b])
        try FileManager.default.moveItem(at: a, to: temp); try FileManager.default.moveItem(at: b, to: a); try FileManager.default.moveItem(at: temp, to: b)
        store.reconcileLibrary([item(a), item(b)], in: root)
        XCTAssertEqual(store.metadata(for: a).tags, ["B"]); XCTAssertEqual(store.metadata(for: b).tags, ["A"])
    }

    func testRenameRejectsTraversalAndCollision() async throws {
        let root = try folder(), url = root.appendingPathComponent("a.png"), other = root.appendingPathComponent("b.png")
        try write(image(), url); try write(image(), other)
        for name in ["../outside", "b", ".hidden"] {
            do { try await LibraryService().rename(item(url), name: name, root: root); XCTFail("Should reject \(name)") } catch {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTilesCoverEveryPixelAndDeduplicateOverlap() {
        let tiles = ScreenshotParserService.tiles(size: CGSize(width: 4300, height: 20000))
        XCTAssertEqual(tiles.map(\.maxY).max(), 20000); XCTAssertEqual(tiles.map(\.maxX).max(), 4300)
        for y in stride(from: 0, through: 19999, by: 37) {
            for x in stride(from: 0, through: 4299, by: 41) { XCTAssertTrue(tiles.contains { $0.contains(CGPoint(x: x, y: y)) }) }
        }
        let a = RecognizedRegion(text: "Hello world", rect: CGRect(x: 0, y: 10, width: 110, height: 20))
        let b = RecognizedRegion(text: "world", rect: CGRect(x: 60, y: 10, width: 50, height: 20))
        XCTAssertTrue(ScreenshotParserService.sameLine(a, b))
        XCTAssertFalse(ScreenshotParserService.sameLine(a, RecognizedRegion(text: "Hello world", rect: a.rect.offsetBy(dx: 0, dy: 50))))
    }

    func testLongImageSearchablePDFKeepsBottomTextAndMasks() async throws {
        let height = 20000
        let cg = try image(width: 1000, height: height) { ctx in
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for (offset, text) in [(100, "FIRSTMARKER Hello world"), (1920, "SEAMMARKER Project report"), (10000, "MIDDLEMARKER Xin chào Việt Nam"), (19800, "LASTMARKER Complete report")] {
                NSString(string: text).draw(at: CGPoint(x: 60, y: height - offset - 36), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            }
            NSString(string: "HIDDENPASSWORD123").draw(at: CGPoint(x: 60, y: height - 400), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 50, y: height - 415, width: 600, height: 65))
        }
        let url = try folder().appendingPathComponent("long.png"); try write(cg, url)
        let started = Date()
        let data = try await CompositionService().pdf([CompositionPage(url: url, caption: "Long image")], captions: true, searchable: true, layout: .a4)
        let pdf = try XCTUnwrap(PDFDocument(data: data)), text = pdf.string ?? ""
        XCTAssertGreaterThan(pdf.pageCount, 10)
        for marker in ["FIRSTMARKER", "MIDDLEMARKER", "LASTMARKER"] { XCTAssertTrue(text.contains(marker), "Missing \(marker): \(text)") }
        XCTAssertFalse(text.contains("HIDDENPASSWORD"))
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 0.05)
        record("ocr_pdf_1000x20000_seconds", Date().timeIntervalSince(started))
    }

    func testPageSlicesBreakBeforeTextWithoutGaps() {
        let size = CGSize(width: 1000, height: 5000)
        let baseline = CompositionService.pageSlices(size: size, layout: .letter, captions: true)
        let seam = baseline[0].maxY
        let line = RecognizedRegion(text: "crossing", rect: CGRect(x: 10, y: seam - 10, width: 400, height: 30))
        let slices = CompositionService.pageSlices(size: size, layout: .letter, captions: true, regions: [line])
        XCTAssertLessThan(slices[0].maxY, line.rect.minY)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.height }, size.height)
        for (a, b) in zip(slices, slices.dropFirst()) { XCTAssertEqual(a.maxY, b.minY) }
    }

    func testQRRecognitionAndSafeLinks() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        let payload = "https://example.com/isnap"
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let code = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let source = try image(width: code.width + 100, height: code.height + 100) { $0.draw(code, in: CGRect(x: 50, y: 50, width: code.width, height: code.height)) }
        let result = try await ScreenshotParserService().parse(source)
        XCTAssertEqual(result.codes.map(\.payload), [payload]); XCTAssertEqual(result.codes.first?.webURL?.host, "example.com")
        XCTAssertNil(RecognizedCode(payload: "javascript:alert(1)", rect: .zero).webURL)
        XCTAssertNil(RecognizedCode(payload: "file:///tmp/private", rect: .zero).webURL)
    }

    func testSubstringRedactionsUseGlyphBoundsAndFallbackSafely() async throws {
        let text = "Name: SECRET ok", range = ("Name: SECRET ok" as NSString).range(of: "SECRET")
        let glyphs = Array(text.utf16.enumerated()).map { RecognizedGlyph(range: NSRange(location: $0.offset, length: 1), rect: CGRect(x: $0.offset * 10, y: 20, width: 10, height: 20)) }
        let line = RecognizedRegion(text: text, rect: CGRect(x: 0, y: 20, width: text.count * 10, height: 20), glyphs: glyphs)
        let matches = try await RedactionMatcher().match([line], rules: [RedactionRule(name: "Secret token", pattern: "SECRET")], wholeLines: false)
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches[0].region.rect, CGRect(x: range.location * 10, y: 20, width: 60, height: 20))
        XCTAssertEqual(matches[0].reason, "Secret token")
        var missing = line; missing.glyphs = Array(glyphs.prefix(7))
        XCTAssertEqual(missing.boundingRect(for: range), line.rect)
    }

    func testPathologicalRegexStopsWithoutPartialResults() async throws {
        let started = Date()
        do {
            _ = try await RedactionMatcher().match([RecognizedRegion(text: String(repeating: "a", count: 4000) + "!", rect: .zero)], rules: [RedactionRule(name: "Slow", pattern: "^(a+)+$", regularExpression: true)], wholeLines: false)
            XCTFail("Expected bounded matching error")
        } catch { XCTAssertTrue(error is RedactionMatchError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testNative4KComparisonDetectsOnePixelAndIgnoresExactRegion() throws {
        let a = try image(width: 4096, height: 2160)
        let b = try image(width: 4096, height: 2160) { ctx in
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 3000, y: 2159 - 100, width: 1, height: 1))
        }
        let started = Date(), diff = try ImageComparisonService.compare(a, b)
        XCTAssertEqual(diff.changedPixels, 1)
        XCTAssertEqual(try ImageComparisonService.compare(a, b, ignored: [CGRect(x: 3000, y: 100, width: 1, height: 1)]).changedPixels, 0)
        XCTAssertEqual(try ImageComparisonService.compare(a, b, threshold: 255).changedPixels, 0)
        XCTAssertEqual(diff.size.width, 4096)
        record("comparison_4k_three_passes_seconds", Date().timeIntervalSince(started))
    }

    @MainActor func testSmoothStrokePartialEraseUndoAndHighlighter() throws {
        let samples = (0..<1000).map { CGPoint(x: CGFloat($0) / 5, y: 50) }
        let reduced = StrokeGeometry.smooth(samples)
        XCTAssertLessThan(reduced.count, 20); XCTAssertEqual(reduced.first, samples.first); XCTAssertEqual(reduced.last, samples.last)
        let doc = EditorDocument(); doc.load(CaptureResult(image: NSImage(cgImage: try image(), size: .zero), sourceName: "Test"))
        var stroke = Annotation.freehand([CGPoint(x: 10, y: 50), CGPoint(x: 190, y: 50)], style: AnnotationStyle()); stroke.type = .highlighter
        stroke.strokeWidth = 20; doc.add(stroke)
        let mask = Annotation(type: .redact, frame: CGRect(x: 90, y: 40, width: 20, height: 20))
        doc.add(mask); doc.beginMutation(); doc.eraseStrokes(at: CGPoint(x: 100, y: 50), radius: 5)
        XCTAssertEqual(doc.annotations.filter { $0.type == .highlighter }.count, 2)
        XCTAssertEqual(doc.annotations.last, mask)
        for part in doc.annotations.filter({ $0.type.isStroke }) { XCTAssertFalse(part.frame.contains(CGPoint(x: 100, y: 50))) }
        doc.undo(); XCTAssertEqual(doc.annotations, [stroke, mask])
        let source = try image { ctx in ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 65, width: 200, height: 10)) }
        let rendered = try ExportRenderer.render(RenderRequest(image: NSImage(cgImage: source, size: .zero), annotations: [stroke], canvas: CanvasConfiguration(), includeBackground: false))
        let pixel = try PixelSample.read(XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)), at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(pixel.hex, "#000000", "Multiply highlighter must preserve black text")
    }

    func testColorSamplerUsesSourcePixelsAndRulerDistance() throws {
        let cg = try image { ctx in ctx.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor); ctx.fill(CGRect(x: 17, y: 120 - 24, width: 1, height: 1)) }
        let sample = try PixelSample.read(cg, at: CGPoint(x: 17, y: 23))
        XCTAssertEqual(sample.hex, "#FF0000"); XCTAssertEqual(sample.y, 23)
        let ruler = Annotation.make(type: .ruler, from: .zero, to: CGPoint(x: 30, y: 40), style: AnnotationStyle())
        XCTAssertTrue(ruler.measurement.contains("50.0 px"))
        XCTAssertThrowsError(try PixelSample.read(cg, at: CGPoint(x: -1, y: 0)))
    }

    @MainActor func testCutOutPreservesPixelsMasksPositionsAndUndo() async throws {
        let cg = try image { ctx in ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 30)) }
        let mask = Annotation(type: .redact, frame: CGRect(x: 40, y: 20, width: 30, height: 70))
        let text = Annotation(type: .text, frame: CGRect(x: 100, y: 95, width: 80, height: 20), text: "Hi")
        let result = try await CutOutService().apply(image: cg, annotations: [mask, text], axis: .horizontal, start: 30, end: 60)
        XCTAssertFalse(result.flattened); XCTAssertEqual(result.image.height, 90)
        XCTAssertEqual(result.annotations[0].frame, CGRect(x: 40, y: 20, width: 30, height: 40))
        XCTAssertEqual(result.annotations[1].frame.minY, 65)
        XCTAssertEqual(try PixelSample.read(result.image, at: CGPoint(x: 10, y: 89)).hex, "#FF0000")
        let doc = EditorDocument(); doc.load(CaptureResult(image: NSImage(cgImage: cg, size: .zero), sourceName: "cut")); doc.add(mask); doc.add(text)
        doc.applyCutOut(result); doc.undo(); XCTAssertEqual(doc.imagePixelSize.height, 120); XCTAssertEqual(doc.annotations, [mask, text])
        doc.redo(); XCTAssertEqual(doc.imagePixelSize.height, 90)
        let crossing = Annotation(type: .rectangle, frame: CGRect(x: 0, y: 10, width: 80, height: 80))
        let flat = try await CutOutService().apply(image: cg, annotations: [crossing, mask], axis: .horizontal, start: 30, end: 60)
        XCTAssertTrue(flat.flattened); XCTAssertTrue(flat.annotations.isEmpty)
        XCTAssertEqual(try PixelSample.read(flat.image, at: CGPoint(x: 50, y: 30)).hex, "#000000")
    }

    func testDirectionalTransformsAndHorizontalCut() throws {
        let cg = try image(width: 30, height: 20) { ctx in ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 19, width: 1, height: 1)) }
        for direction in ScrollDirection.allCases {
            let rotated = try direction.orient(cg), restored = try direction.inverse.orient(rotated)
            XCTAssertEqual(try ImageComparisonService.compare(cg, restored).changedPixels, 0)
        }
        let right = try ScrollDirection.right.orient(cg)
        XCTAssertEqual(try PixelSample.read(right, at: CGPoint(x: 19, y: 0)).hex, "#FF0000")
        let cut = try CutOutService.cut(cg, axis: .vertical, start: 10, end: 20)
        XCTAssertEqual(cut.width, 20); XCTAssertEqual(try PixelSample.read(cut, at: .zero).hex, "#FF0000")
    }

    func testGuidePersistsOrderExportsAndRejectsExistingFolder() async throws {
        let root = try folder(), service = GuideService(directory: root.appendingPathComponent("draft"))
        var draft = try await service.append(image(), draft: GuideDraft())
        draft = try await service.append(image(), draft: draft)
        draft.steps.reverse(); draft.steps[0].caption = "Click [Save] <script>"; draft.title = "Workflow"
        try await service.save(draft)
        let restored = try await service.load(); XCTAssertEqual(restored, draft)
        let target = root.appendingPathComponent("markdown")
        try await service.export(draft, to: target, pdf: false)
        let markdown = try String(contentsOf: target.appendingPathComponent("README.md"))
        XCTAssertTrue(markdown.contains("Click \\[Save\\] \\<script\\>")); XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("step-002.png").path))
        do { try await service.export(draft, to: target, pdf: false); XCTFail("Must not overwrite folder") } catch {}
        let pdfURL = root.appendingPathComponent("guide.pdf")
        try await service.export(draft, to: pdfURL, pdf: true)
        XCTAssertEqual(PDFDocument(url: pdfURL)?.pageCount, 2)
    }

    @MainActor func testUpdaterConfigurationRejectsInsecureOrMissingKeys() {
        XCTAssertFalse(AppUpdater.configured([:]))
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertFalse(AppUpdater.configured(["SUFeedURL": "http://example.com/feed", "SUPublicEDKey": key]))
        XCTAssertFalse(AppUpdater.configured(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": "invalid"]))
        XCTAssertTrue(AppUpdater.configured(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": key]))
    }

    @MainActor func testLargeLibraryMetadataAndWriteFailure() async throws {
        let root = try folder(), store = WorkspaceFeatures(url: root.appendingPathComponent("metadata.json"))
        let items = (0..<10000).map { LibraryItem(url: root.appendingPathComponent("\($0).png"), modifiedAt: Date(), dimensions: .zero, fileIdentity: "file-\($0)") }
        let start = Date(); store.reconcileLibrary(items, in: root)
        let backup = try store.exportLibraryMetadata(); try store.importLibraryMetadata(backup)
        XCTAssertEqual(store.state.metadata.count, 10000)
        record("metadata_10000_reconcile_backup_import_seconds", Date().timeIntervalSince(start))
        let blocked = root.appendingPathComponent("file"); try Data([1]).write(to: blocked)
        do { try await BackgroundExportService().write(Data([2]), to: blocked.appendingPathComponent("child.png")); XCTFail("Expected disk write error") } catch {}
        XCTAssertEqual(try Data(contentsOf: blocked), Data([1]))
    }

    @MainActor func testCanvasAccessibilitySelectsLayerAndKeyboardMovesIt() throws {
        let document = EditorDocument()
        document.load(CaptureResult(image: NSImage(cgImage: try image(), size: .zero), sourceName: "Accessible"))
        let layer = Annotation(type: .rectangle, frame: CGRect(x: 20, y: 20, width: 60, height: 40))
        document.add(layer); document.selectedAnnotationID = nil
        let view = InteractiveCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400)); view.document = document
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let children = try XCTUnwrap(view.accessibilityChildren())
        XCTAssertEqual(children.count, 1)
        let child = try XCTUnwrap(children.first as? NSAccessibilityElement)
        XCTAssertTrue(child.accessibilityPerformPress()); XCTAssertEqual(document.selectedAnnotationID, layer.id)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: event); XCTAssertEqual(document.annotations[0].frame.minX, 30)
        window.orderOut(nil)
    }

    func testManyLayersAndBatchPresetBenchmark() async throws {
        let cg = try image(width: 2400, height: 1600)
        let samples = (0..<1000).map { CGPoint(x: CGFloat($0), y: sin(CGFloat($0) / 80) * 20) }
        let started = Date()
        let smooth = StrokeGeometry.smooth(samples)
        let layers = (0..<500).map { index -> Annotation in
            var stroke = Annotation.freehand(smooth, style: AnnotationStyle())
            stroke.frame.origin = CGPoint(x: index % 10 * 120, y: index / 10 * 28 + 30)
            stroke.strokeWidth = 2; return stroke
        }
        let rendered = try await BackgroundExportService().render(ImageRenderSnapshot(image: cg, annotations: layers,
            canvas: .sourcePixels, includeBackground: false), format: .png, quality: 1)
        XCTAssertEqual(rendered.image.width, 2400); XCTAssertGreaterThan(rendered.data.count, 1000)
        record("render_500_smoothed_strokes_2400x1600_seconds", Date().timeIntervalSince(started))
        let root = try folder(), source = root.appendingPathComponent("source.png")
        try write(image(width: 1000, height: 800), source)
        let original = try Data(contentsOf: source)
        var canvas = CanvasConfiguration(); canvas.showBackground = true
        let options = BatchExportOptions(canvas: canvas, maxDimension: 600, prefix: "preset")
        let service = BatchExportService(), batchStart = Date()
        for i in 1...8 {
            let output = try await service.export(source, to: root, index: i, options: options)
            let size = try XCTUnwrap(ImageIOService.pixelSize(at: output))
            XCTAssertLessThanOrEqual(max(size.width, size.height), 600)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        record("batch_preset_8_images_seconds", Date().timeIntervalSince(batchStart))
    }

    @MainActor func testScrollControllerFinishesAllFourDirectionsAndPreservesFailedSession() async throws {
        let canonical = try image(width: 80, height: 180) { ctx in
            for row in 0..<180 {
                ctx.setFillColor(NSColor(srgbRed: Double(row % 13) / 13, green: Double(row % 7) / 7, blue: Double(row % 19) / 19, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: row, width: 80, height: 1))
            }
        }
        let first = try XCTUnwrap(canonical.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 120)))
        let next = try XCTUnwrap(canonical.cropping(to: CGRect(x: 0, y: 60, width: 80, height: 120)))
        for direction in ScrollDirection.allCases {
            let controller = ScrollCaptureController(), source = try direction.inverse.orient(canonical)
            let nextInput = try direction.inverse.orient(next)
            var output: NSImage?
            controller.begin(first: try direction.inverse.orient(first), capture: { nextInput }, presentsPanel: false, completion: { output = $0 })
            controller.direction = direction; controller.changeDirection(); controller.captureNext()
            for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(controller.pending)
            controller.overlap = 60; controller.addPending(); controller.finish()
            for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
            let result = try XCTUnwrap(output?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(try ImageComparisonService.compare(source, result).changedPixels, 0, direction.rawValue)
        }
        let controller = ScrollCaptureController()
        controller.begin(first: first, capture: { next }, scroll: { throw ScrollSourceGuard.SourceChanged() }, presentsPanel: false, completion: { _ in })
        controller.startAutomatic()
        for _ in 0..<100 { if !controller.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.frames.count, 1); XCTAssertNil(controller.pending); XCTAssertFalse(controller.message.isEmpty)
        controller.cancel()
    }

    private func record(_ name: String, _ value: Double) {
        print("ISNAP_BENCHMARK \(name)=\(String(format: "%.4f", value))")
        if let path = ProcessInfo.processInfo.environment["ISNAP_BENCHMARK_PATH"] {
            let url = URL(fileURLWithPath: path)
            var values = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))) ?? [:]
            values[name] = value
            if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
        }
    }
}
