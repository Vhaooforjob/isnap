import XCTest
import AppKit
@testable import iSnap

final class WorkspaceFeatureTests: XCTestCase {
    private func fixture(width: Int = 128, height: Int = 800) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(((y * 73 + (y / 7) * 31) ^ (x * 17)) % 256)
                let offset = (y * width + x) * 4
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testScrollingOverlapAndPixelPerfectStitch() throws {
        let original = try fixture()
        let first = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 0, width: 128, height: 500)))
        let next = try XCTUnwrap(original.cropping(to: CGRect(x: 0, y: 300, width: 128, height: 500)))
        let overlap = try XCTUnwrap(ScrollingStitcher.estimateOverlap(previous: first, next: next))
        XCTAssertEqual(overlap, 200, accuracy: 2)
        let stitched = try ScrollingStitcher.stitch([first, next], overlaps: [200])
        XCTAssertEqual(stitched.height, 800)
        XCTAssertEqual(pixels(stitched), pixels(original))
    }

    func testScrollingRejectsInvalidFramesAndAmbiguousBlankContent() throws {
        let image = try fixture(width: 80, height: 80)
        let other = try fixture(width: 81, height: 80)
        XCTAssertThrowsError(try ScrollingStitcher.stitch([image, other], overlaps: [20]))
        XCTAssertThrowsError(try ScrollingStitcher.stitch([image, image], overlaps: [80]))
        XCTAssertThrowsError(try ScrollingStitcher.stitch([image, image], overlaps: [-1]))
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let blank = try XCTUnwrap(context.makeImage())
        XCTAssertNil(ScrollingStitcher.estimateOverlap(previous: blank, next: blank))
    }

    @MainActor
    func testProjectRoundTripKeepsLayersAndOriginalCrop() throws {
        let document = EditorDocument()
        let image = try fixture(width: 128, height: 100)
        document.load(CaptureResult(image: NSImage(cgImage: image, size: CGSize(width: 128, height: 100)), sourceName: "Example"))
        document.add(Annotation(type: .arrow, frame: CGRect(x: 20, y: 20, width: 25, height: 25)))
        document.canvas.watermark = WatermarkConfiguration()
        document.cropRect = CGRect(x: 10, y: 10, width: 80, height: 70)
        document.applyCrop()
        let stored = try JSONEncoder().encode(document.project())
        let restored = EditorDocument()
        try restored.loadProject(JSONDecoder().decode(EditorProject.self, from: stored))
        XCTAssertEqual(restored.annotations, document.annotations)
        XCTAssertEqual(restored.canvas, document.canvas)
        XCTAssertTrue(restored.isCropApplied)
        XCTAssertEqual(restored.imagePixelSize, CGSize(width: 80, height: 70))
        restored.resetCrop()
        XCTAssertEqual(restored.imagePixelSize, CGSize(width: 128, height: 100))
        XCTAssertEqual(restored.annotations[0].frame.origin, CGPoint(x: 20, y: 20))
        restored.undo()
        XCTAssertEqual(restored.imagePixelSize, CGSize(width: 80, height: 70))
        var future = try document.project(); future.version = 99
        XCTAssertThrowsError(try restored.loadProject(future))
        XCTAssertEqual(restored.imagePixelSize, CGSize(width: 80, height: 70))
    }

    func testRedactionCoversSourceAndLaterOverlays() throws {
        let image = try fixture(width: 128, height: 100)
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
        let mask = Annotation(type: .redact, frame: CGRect(x: 20, y: 10, width: 40, height: 30))
        var overlay = Annotation(type: .rectangle, frame: mask.frame)
        overlay.fill = .white; overlay.stroke = .white
        let rendered = try ExportRenderer.render(RenderRequest(image: NSImage(cgImage: image, size: CGSize(width: 128, height: 100)),
            annotations: [mask, overlay], canvas: canvas, includeBackground: false))
        let cg = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let values = pixels(cg), source = pixels(image)
        for y in 12..<38 {
            for x in 22..<58 {
                let offset = (y * 128 + x) * 4
                XCTAssertEqual(Array(values[offset..<(offset + 4)]), [0, 0, 0, 255])
            }
        }
        let outside = (70 * 128 + 90) * 4
        XCTAssertEqual(Array(values[outside..<(outside + 4)]), Array(source[outside..<(outside + 4)]))
    }

    func testBlurAndPixelateAffectOnlySelectedRegion() throws {
        let image = try fixture(width: 128, height: 100)
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
        let source = pixels(image)
        for tool in [EditorTool.blur, .pixelate] {
            let annotation = Annotation(type: tool, frame: CGRect(x: 20, y: 10, width: 40, height: 30))
            let rendered = try ExportRenderer.render(RenderRequest(image: NSImage(cgImage: image, size: CGSize(width: 128, height: 100)),
                annotations: [annotation], canvas: canvas, includeBackground: false))
            let values = pixels(try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            XCTAssertNotEqual(values[(20 * 128 + 30) * 4], source[(20 * 128 + 30) * 4])
            XCTAssertGreaterThan(values[(20 * 128 + 30) * 4], 0, "The filter must render, not fall back to a solid mask")
            XCTAssertLessThan(values[(20 * 128 + 30) * 4], 255)
            XCTAssertEqual(values[(70 * 128 + 90) * 4], source[(70 * 128 + 90) * 4])
        }
    }

    @MainActor
    func testWorkspacePersistsPresetsTagsAndCapturePreferences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workspace.json")
        let store = WorkspaceFeatures(url: url)
        store.state.captureDelay = 5; store.state.showsCursor = true
        store.state.presets = [CanvasPreset(name: "Docs", canvas: CanvasConfiguration())]
        let image = folder.appendingPathComponent("shot.png")
        store.setMetadata(LibraryMetadata(favorite: true, tags: ["bug", "UI"]), for: image)
        let restored = WorkspaceFeatures(url: url)
        XCTAssertEqual(restored.state.captureDelay, 5)
        XCTAssertTrue(restored.state.showsCursor)
        XCTAssertEqual(restored.state.presets.first?.name, "Docs")
        XCTAssertEqual(restored.metadata(for: image).tags, ["bug", "UI"])
        XCTAssertTrue(restored.metadata(for: image).favorite)
    }

    func testBatchExportResizesAndNeverOverwritesInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try fixture(width: 128, height: 100)
        let data = try ProjectStore.png(NSImage(cgImage: image, size: CGSize(width: 128, height: 100)))
        let input = folder.appendingPathComponent("shot.png")
        try data.write(to: input)
        var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
        let exporter = BatchExportService()
        let options = BatchExportOptions(canvas: canvas, maxDimension: 64, prefix: "")
        let output = try await exporter.export(input, to: folder, index: 1, options: options)
        let second = try await exporter.export(input, to: folder, index: 2, options: options)
        XCTAssertNotEqual(output, input); XCTAssertNotEqual(second, output)
        XCTAssertEqual(try Data(contentsOf: input), data)
        XCTAssertEqual(ImageIOService.pixelSize(at: output), CGSize(width: 64, height: 50))
    }

    func testSensitiveSuggestionsFindEmailButDoNotFlagPlainText() {
        XCTAssertTrue(RecognizedRegion(text: "Contact jane@example.com", rect: .zero).mayContainPrivateInformation)
        XCTAssertFalse(RecognizedRegion(text: "Connection refused", rect: .zero).mayContainPrivateInformation)
    }

    @MainActor
    func testSuggestedMasksUndoTogether() throws {
        let document = EditorDocument()
        let image = try fixture(width: 128, height: 100)
        document.load(CaptureResult(image: NSImage(cgImage: image, size: CGSize(width: 128, height: 100)), sourceName: "Example"))
        document.addPrivacyMasks([CGRect(x: 10, y: 10, width: 40, height: 10), CGRect(x: 10, y: 50, width: 50, height: 10)])
        XCTAssertEqual(document.annotations.count, 2)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        document.redo()
        XCTAssertEqual(document.annotations.count, 2)
    }

    func testSearchIndexPersistsAndInvalidatesModifiedImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("text.png")
        let indexURL = folder.appendingPathComponent("index.json")
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 180, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 180))
        let source = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 900, height: 180))
        func writeText(_ text: String) throws {
            var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
            let annotation = Annotation(type: .text, frame: CGRect(x: 30, y: 30, width: 800, height: 100),
                stroke: RGBAColor(.black), text: text, fontSize: 58)
            let image = try ExportRenderer.render(RenderRequest(image: source, annotations: [annotation], canvas: canvas, includeBackground: false))
            try ProjectStore.png(image).write(to: input)
        }
        try writeText("INVOICE 4289")
        let index = LibrarySearchIndex(url: indexURL)
        let firstDate = Date(timeIntervalSince1970: 100)
        let first = try await index.text(for: input, modifiedAt: firstDate)
        XCTAssertTrue(first.contains("4289"))
        try await index.save()
        let reopened = LibrarySearchIndex(url: indexURL)
        let cached = try await reopened.text(for: input, modifiedAt: firstDate)
        XCTAssertEqual(cached, first)
        try writeText("RECEIPT 7351")
        let changed = try await reopened.text(for: input, modifiedAt: firstDate.addingTimeInterval(1))
        XCTAssertTrue(changed.contains("7351"))
        XCTAssertFalse(changed.contains("4289"))
        await reopened.remove([input])
        try await reopened.save()
        let entries = try JSONDecoder().decode([String: IndexedScreenshot].self, from: Data(contentsOf: indexURL))
        XCTAssertTrue(entries.isEmpty)
    }
}
