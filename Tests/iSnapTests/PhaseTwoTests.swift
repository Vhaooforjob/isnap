import AppKit
import XCTest
@testable import iSnap

final class PhaseTwoTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image(_ color: NSColor = .white, width: Int = 100, height: Int = 60) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
    @MainActor private func document() throws -> EditorDocument {
        let doc = EditorDocument()
        doc.load(CaptureResult(image: NSImage(cgImage: try image(), size: CGSize(width: 100, height: 60)), sourceName: "Test"))
        return doc
    }
    func testSnapEdgesCentersSizesAndEqualGaps() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let peer = CGRect(x: 100, y: 100, width: 30, height: 40)
        let moved = SnapEngine.snap(CGRect(x: 98, y: 200, width: 30, height: 40), peers: [peer], bounds: bounds, tolerance: 4)
        XCTAssertEqual(moved.frame.minX, 100)
        XCTAssertEqual(moved.frame.minY, 200)
        let centered = SnapEngine.snap(CGRect(x: 489, y: 300, width: 20, height: 20), peers: [], bounds: bounds, tolerance: 3)
        XCTAssertEqual(centered.frame.midX, 500)
        let sized = SnapEngine.snap(CGRect(x: 300, y: 300, width: 28, height: 39), peers: [peer], bounds: bounds, tolerance: 3, resizing: true)
        XCTAssertEqual(sized.frame.size, peer.size)
        let peers = [CGRect(x: 100, y: 100, width: 20, height: 20), CGRect(x: 150, y: 100, width: 20, height: 20)]
        let after = SnapEngine.snap(CGRect(x: 198, y: 100, width: 14, height: 20), peers: peers, bounds: bounds, tolerance: 3)
        XCTAssertEqual(after.frame.minX, 200)
        XCTAssertNotNil(after.guides.first(where: { $0.vertical })?.label)
        let before = SnapEngine.snap(CGRect(x: 58, y: 100, width: 14, height: 20), peers: peers, bounds: bounds, tolerance: 3)
        XCTAssertEqual(before.frame.maxX, 70)
        let between = SnapEngine.snap(CGRect(x: 127, y: 100, width: 14, height: 20), peers: peers, bounds: bounds, tolerance: 3)
        XCTAssertEqual(between.frame.midX, 135)
        let far = CGRect(x: 350, y: 350, width: 10, height: 10)
        XCTAssertEqual(SnapEngine.snap(far, peers: peers, bounds: bounds, tolerance: 3).frame, far)
    }
    @MainActor func testLayerLockVisibilityGeometryAndUndo() throws {
        let doc = try document()
        var a = Annotation(type: .rectangle, frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        a.locked = true
        var b = Annotation(type: .rectangle, frame: CGRect(x: 40, y: 30, width: 20, height: 20))
        b.hidden = true
        let c = Annotation(type: .rectangle, frame: CGRect(x: 65, y: 35, width: 20, height: 20))
        [a,b,c].forEach(doc.add); doc.selectAllAnnotations()
        doc.moveSelection(dx: 5, dy: 5); doc.alignSelection(.left)
        XCTAssertEqual(doc.annotations[0], a); XCTAssertEqual(doc.annotations[1], b)
        XCTAssertEqual(doc.annotations[2].frame.minX, 70)
        doc.setFrame(CGRect(x: 1, y: 1, width: 40, height: 40), for: a.id)
        XCTAssertEqual(doc.annotations[0], a)
        doc.updateLayer(a.id, name: "Locked", hidden: true)
        XCTAssertEqual(doc.annotations[0].displayName, "Locked"); XCTAssertTrue(doc.annotations[0].isHidden)
        doc.undo(); XCTAssertEqual(doc.annotations[0], a)
        doc.moveLayer(a.id, before: c.id)
        XCTAssertEqual(doc.annotations.last?.id, a.id)
        doc.undo(); doc.selectAllAnnotations(); doc.deleteSelection()
        XCTAssertEqual(doc.annotations, [a])
        let legacy = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(legacy.isHidden); XCTAssertFalse(legacy.isLocked)
    }
    @MainActor func testSharedDraftAssetsFallbackAndPortableProject() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let latest = folder.appendingPathComponent("Latest.isnap")
        let doc = try document(), project = try doc.project()
        try ProjectStore.writeDraft(project, to: latest)
        var changed = project; changed.sourceName = "Changed"
        try ProjectStore.writeDraft(changed, to: latest)
        let assets = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(".Assets"), includingPropertiesForKeys: nil)
        XCTAssertEqual(assets.count, 1)
        let manifest = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: latest))
        XCTAssertTrue(manifest.image.isEmpty); XCTAssertEqual(manifest.assets?.count, 1)
        XCTAssertEqual(try ProjectStore.read(latest).image, project.image)
        let portable = folder.appendingPathComponent("Export.isnap")
        try ProjectStore.write(ProjectStore.read(latest), to: portable)
        let decoded = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: portable))
        XCTAssertNil(decoded.assets); XCTAssertEqual(decoded.image, project.image)
        try Data("broken".utf8).write(to: latest)
        XCTAssertEqual(try ProjectStore.recover(in: folder).sourceName, project.sourceName)
        XCTAssertThrowsError(try ProjectStore.collectAssets(in: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets[0].path))
        var invalid = project; invalid.image = Data([1,2,3])
        try ProjectStore.write(invalid, to: latest)
        XCTAssertEqual(try ProjectStore.recover(in: folder).sourceName, project.sourceName)
        try Data([1]).write(to: assets[0])
        XCTAssertThrowsError(try ProjectStore.read(folder.appendingPathComponent("Previous.isnap")))
    }
    @MainActor func testPixelAlignmentAndSpaceMoveCaptureImmediatelyOnRelease() throws {
        XCTAssertEqual(RegionSelectionView.pixelAligned(CGRect(x: 1.24, y: 2.26, width: 10.5, height: 20.5), scale: 2),
            CGRect(x: 1, y: 2.5, width: 10.5, height: 20.5))
        let view = RegionSelectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var result: CGRect?
        view.onComplete = { result = $0 }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, 10, 20))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 70, 80))
        XCTAssertNil(result)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        view.keyDown(with: space)
        view.mouseDragged(with: try mouse(.leftMouseDragged, 90, 100))
        XCTAssertNil(result)
        view.mouseUp(with: try mouse(.leftMouseUp, 90, 100))
        XCTAssertEqual(result, CGRect(x: 30, y: 40, width: 60, height: 60))
    }
    func testOCRRowsLayoutAndCSVPreserveMissingCellsAndQuotes() {
        let regions = [RecognizedRegion(text: "A,\"B\"", rect: CGRect(x: 10, y: 10, width: 30, height: 10)),
                       RecognizedRegion(text: "12", rect: CGRect(x: 100, y: 11, width: 20, height: 10)),
                       RecognizedRegion(text: "34", rect: CGRect(x: 100, y: 30, width: 20, height: 10))]
        XCTAssertEqual(OCRLayout.rows(regions.reversed()).map(\.count), [2,1])
        XCTAssertEqual(OCRLayout.csv(regions), "\"A,\"\"B\"\"\",\"12\"\r\n\"\",\"34\"")
        XCTAssertEqual(OCRLayout.plain(regions, preserveLayout: false), "A,\"B\" 12\n34")
        XCTAssertTrue(OCRLayout.plain(regions, preserveLayout: true).contains("      "))
        XCTAssertEqual(OCRLayout.csv([]), "")
    }
    func testBackgroundExportVisibilityAndCancelledWrite() async throws {
        let source = try image()
        var mask = Annotation(type: .redact, frame: CGRect(x: 0, y: 0, width: 100, height: 60)); mask.hidden = true
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
        let service = BackgroundExportService()
        let hidden = try await service.render(ImageRenderSnapshot(image: source, annotations: [mask], canvas: canvas, includeBackground: false), format: .png, quality: 1)
        let plain = try await service.render(ImageRenderSnapshot(image: source, annotations: [], canvas: canvas, includeBackground: false), format: .png, quality: 1)
        XCTAssertEqual(hidden.data, plain.data)
        mask.hidden = false
        let visible = try await service.render(ImageRenderSnapshot(image: source, annotations: [mask], canvas: canvas, includeBackground: false), format: .png, quality: 1)
        XCTAssertNotEqual(visible.data, plain.data)
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cancel.png")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.write(plain.data, to: url)
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testCompositionDimensionsOrderingAndPDFPages() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let urls = [dir.appendingPathComponent("red.png"), dir.appendingPathComponent("blue.png")]
        for (url, color) in zip(urls, [NSColor.red, .blue]) {
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image(color)).representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
        let pages = urls.map { CompositionPage(url: $0, caption: $0.lastPathComponent) }
        let service = CompositionService()
        var options = CompositionOptions(); options.captions = false; options.spacing = 10
        let vertical = try await service.combine(pages, options: options)
        XCTAssertEqual(vertical.width, 120); XCTAssertEqual(vertical.height, 150)
        let bitmap = NSBitmapImageRep(cgImage: vertical)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 50, y: 110)?.usingColorSpace(.deviceRGB)).blueComponent, 0.9)
        options.horizontal = true
        let horizontal = try await service.combine(pages, options: options)
        XCTAssertEqual(horizontal.width, 230); XCTAssertEqual(horizontal.height, 80)
        let data = try await service.pdf(pages, captions: true)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 100, height: 108))
        options.crossDimension = 50
        let small = try await service.combine(pages, options: options)
        XCTAssertLessThan(small.width, horizontal.width)
    }
    @MainActor func testWorkflowDefaultsValidationAndLegacyWorkspace() throws {
        let workflow = CaptureWorkflow()
        XCTAssertNil(workflow.uploadProvider)
        XCTAssertTrue(CaptureWorkflow.isValid([workflow]))
        var duplicate = workflow; duplicate.id = UUID(); duplicate.shortcut = "ctrl+alt+9"
        XCTAssertFalse(CaptureWorkflow.isValid([workflow, duplicate]))
        duplicate.shortcut = "9"
        XCTAssertFalse(CaptureWorkflow.isValid([duplicate]))
        let data = Data(#"{"presets":[],"metadata":{},"captureDelay":0,"showsCursor":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceState.self, from: data).workflows)
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.json")
        let store = WorkspaceFeatures(url: url)
        store.state.workflows = [workflow]
        XCTAssertEqual(WorkspaceFeatures(url: url).state.workflows, [workflow])
    }

    @MainActor func testExactGeometryScalesLineEndpointsAndLayerReorderingBothWays() throws {
        let doc = try document()
        var line = Annotation(type: .arrow, frame: .zero)
        line.setLineEndpoints(start: CGPoint(x: 40, y: 10), end: CGPoint(x: 10, y: 30))
        let other = Annotation(type: .ellipse, frame: CGRect(x: 60, y: 10, width: 20, height: 20))
        doc.add(line); doc.add(other)
        doc.setFrame(CGRect(x: 5, y: 6, width: 60, height: 40), for: line.id)
        XCTAssertEqual(doc.annotations[0].lineStartPoint, CGPoint(x: 65, y: 6))
        XCTAssertEqual(doc.annotations[0].lineEndPoint, CGPoint(x: 5, y: 46))
        doc.undo(); XCTAssertEqual(doc.annotations[0], line)
        doc.moveLayer(other.id, before: line.id)
        XCTAssertEqual(doc.annotations.map(\.id), [other.id, line.id])
        doc.moveLayer(other.id, before: line.id)
        XCTAssertEqual(doc.annotations.map(\.id), [line.id, other.id])
    }

    @MainActor func testDraftThumbnailUsesEmbeddedBackgroundAndInvalidatesAfterEdit() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try document()
        var project = try doc.project()
        project.canvas.showBackground = true; project.canvas.padding = 20
        project.canvas.cornerRadius = 0; project.canvas.shadowSize = 0
        project.canvas.backgroundImageURL = dir.appendingPathComponent("missing.png")
        project.backgroundImage = try XCTUnwrap(NSBitmapImageRep(cgImage: image(.red)).representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent("Draft.isnap")
        try ProjectStore.writeDraft(project, to: url)
        let catalog = DraftCatalog()
        let rendered = try await catalog.thumbnail(url)
        let first = try XCTUnwrap(rendered)
        let cached = try await catalog.thumbnail(url)
        XCTAssertTrue(first === cached)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: first).colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.1)
        project.annotations = [Annotation(type: .redact, frame: CGRect(x: 0, y: 0, width: 100, height: 60))]
        try ProjectStore.writeDraft(project, to: url)
        let updated = try await catalog.thumbnail(url)
        XCTAssertFalse(first === updated)
        let center = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(updated)).colorAt(x: 50, y: 40)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.1)
    }
}
