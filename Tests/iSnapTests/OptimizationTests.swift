import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import iSnap

final class OptimizationTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isnap-optimization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func image(_ color: NSColor = .white, width: Int = 200, height: Int = 100) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }
    private func save(_ cg: CGImage, _ url: URL) throws {
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
    private func item(_ url: URL) -> iSnap.LibraryItem {
        iSnap.LibraryItem(url: url, modifiedAt: Date(), dimensions: .zero)
    }
    func testSmoothingProcessesPendingLeftBranchAfterAdjacentRightBranch() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 9), CGPoint(x: 2, y: -20), CGPoint(x: 3, y: 0)]
        let smooth = StrokeGeometry.smooth(points)
        XCTAssertEqual(smooth.count, 8)
        XCTAssertEqual(smooth[1], CGPoint(x: 0.25, y: 2.25))
        XCTAssertEqual(smooth.first, points.first); XCTAssertEqual(smooth.last, points.last)
    }
    func testEXIFOrientationMatchesDecodedGeometryAndBatchOutput() async throws {
        let root = try folder(), url = root.appendingPathComponent("rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 120, height: 80), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(ImageIOService.pixelSize(at: url), CGSize(width: 80, height: 120))
        let decoded = try ImageIOService.fullImage(at: url)
        XCTAssertEqual(decoded.width, 80); XCTAssertEqual(decoded.height, 120)
        let result = try await BatchExportService().export(url, to: root, index: 1,
            options: BatchExportOptions(canvas: .sourcePixels, maxDimension: 60))
        XCTAssertEqual(ImageIOService.pixelSize(at: result), CGSize(width: 40, height: 60))
    }
    func testBoundedBatchPreservesOriginalCanvasScaleAndSourceFile() async throws {
        let root = try folder(), input = root.appendingPathComponent("large.png")
        let cg = try image(.red, width: 3000, height: 2000); try save(cg, input)
        let original = try Data(contentsOf: input)
        var canvas = CanvasConfiguration.sourcePixels
        canvas.showBackground = true; canvas.padding = 300
        canvas.gradient = GradientPreset.presets[0]
        let result = try await BatchExportService().export(input, to: root, index: 1,
            options: BatchExportOptions(canvas: canvas, maxDimension: 600))
        let output = try ImageIOService.fullImage(at: result)
        XCTAssertEqual(output.width, 600); XCTAssertEqual(output.height, 434)
        XCTAssertEqual(try PixelSample.read(output, at: CGPoint(x: 80, y: 80)).hex, "#FF0000")
        XCTAssertNotEqual(try PixelSample.read(output, at: CGPoint(x: 20, y: 20)).hex, "#FF0000")
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testComparisonInvalidatesCacheAfterAtomicReplacementAndMergesIgnoredRanges() async throws {
        let root = try folder(), a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        try save(image(), a); try save(image(), b)
        let service = ImageComparisonService()
        let initial = try await service.load([a, b]); XCTAssertEqual(initial.changedPixels, 0)
        let date = try FileRevision.read(b).modified
        try save(image(.black), b)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: b.path)
        let changed = try await service.load([a, b]); XCTAssertEqual(changed.changedPixels, 20000)
        XCTAssertEqual(ImageComparisonService.mergedIntervals([10..<30, 0..<5, 4..<12, 40..<42]), [0..<30, 40..<42])
        let ignored = try await service.load([a, b], ignored: [CGRect(x: 0, y: 0, width: 110, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)])
        XCTAssertEqual(ignored.changedPixels, 0)
    }
    func testThumbnailCacheInvalidatesFileIdentityEvenWithSameDateAndSize() async throws {
        let root = try folder(), url = root.appendingPathComponent("thumbnail.png")
        try save(image(.white), url)
        let date = Date(timeIntervalSince1970: 100)
        let old = iSnap.LibraryItem(url: url, modifiedAt: date, dimensions: CGSize(width: 200, height: 100), byteCount: 100,
            fileIdentity: FileIdentity.read(url))
        let firstImage = await ThumbnailCache.shared.image(for: old, maxPixelSize: 40)
        let first = try XCTUnwrap(firstImage)
        try save(image(.black), url)
        let replacement = iSnap.LibraryItem(url: url, modifiedAt: date, dimensions: old.dimensions, byteCount: old.byteCount,
            fileIdentity: FileIdentity.read(url))
        XCTAssertNotEqual(old.fileIdentity, replacement.fileIdentity)
        let secondImage = await ThumbnailCache.shared.image(for: replacement, maxPixelSize: 40)
        let second = try XCTUnwrap(secondImage)
        XCTAssertEqual(try PixelSample.read(first, at: CGPoint(x: 10, y: 10)).hex, "#FFFFFF")
        XCTAssertEqual(try PixelSample.read(second, at: CGPoint(x: 10, y: 10)).hex, "#000000")
    }
    func testStreamingDuplicateScanOnlyHashesSizeCandidatesAndVerifiesContents() async throws {
        let root = try folder()
        let names = ["a.png", "copy.png", "different.png", "unique.png"]
        let payload = Data(repeating: 42, count: 2_100_123)
        for (name, data) in zip(names, [payload, payload, Data(repeating: 43, count: payload.count), Data([1, 2, 3])]) {
            try data.write(to: root.appendingPathComponent(name))
        }
        let urls = names.map { root.appendingPathComponent($0) }
        let scan = try await DuplicateFileService().scan(urls.map(item) + [item(urls[0]), item(root.appendingPathComponent("missing.png"))])
        XCTAssertEqual(scan.hashedFiles, 3); XCTAssertEqual(scan.groups.count, 1)
        XCTAssertEqual(Set(scan.groups[0].items.map(\.name)), ["a.png", "copy.png"])
        XCTAssertEqual(scan.skipped, ["missing.png"])
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(scan.groups[0].digest, digest)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        try Data(repeating: 10, count: payload.count).write(to: urls[1], options: .atomic)
        let next = try await DuplicateFileService().scan(urls.map(item)); XCTAssertTrue(next.groups.isEmpty)
    }
    @MainActor func testDuplicateScanCancellationReturnsNoPartialResult() async throws {
        let root = try folder(), url = root.appendingPathComponent("a.png")
        try Data(repeating: 1, count: 100).write(to: url)
        let service = DuplicateFileService()
        let task = Task { try await service.scan([item(url), item(url)]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testCommandSearchEnglishVietnameseAndDisabledActions() throws {
        var calls = 0
        let commands = [
            WorkspaceCommand(id: "cut", title: "Cắt bỏ dải ảnh", category: "Tools", symbol: "scissors", keywords: "cut out", perform: { calls += 1 }),
            WorkspaceCommand(id: "copy", title: "Copy", category: "iSnap", symbol: "doc", enabled: false, perform: { calls += 1 })
        ]
        XCTAssertEqual(WorkspaceCommand.search(commands, query: "CAT DAI").map(\.id), ["cut"])
        XCTAssertEqual(WorkspaceCommand.search(commands, query: "cut out").map(\.id), ["cut"])
        XCTAssertFalse(WorkspaceCommand.search(commands, query: "copy")[0].enabled)
        XCTAssertEqual(calls, 0, "Searching must never execute a command")
        XCTAssertTrue(WorkspaceCommand.search(commands, query: "unknown").isEmpty)
    }
    @MainActor func testWorkspaceCommandsReflectImageAvailabilityAndDispatchAfterDismiss() throws {
        let root = try folder(), suite = "isnap-command-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: SettingsStore(fileURL: root.appendingPathComponent("settings.json"), userDefaults: defaults),
            captureLine: CaptureLine(ownedFolder: root.appendingPathComponent("line"), defaults: defaults), connectsServices: false,
            features: WorkspaceFeatures(url: root.appendingPathComponent("workspace.json")))
        XCTAssertFalse(try XCTUnwrap(model.workspaceCommands.first { $0.id == "tool.ruler" }).enabled)
        model.document.load(CaptureResult(image: NSImage(cgImage: try image(), size: .zero), sourceName: "Test"))
        let ruler = try XCTUnwrap(model.workspaceCommands.first { $0.id == "tool.ruler" })
        XCTAssertTrue(ruler.enabled)
        model.pendingCommand = ruler.perform; model.finishCommandSearch()
        XCTAssertEqual(model.document.tool, .ruler); XCTAssertNil(model.pendingCommand)
        XCTAssertEqual(Set(model.workspaceCommands.map(\.id)).count, model.workspaceCommands.count)
        XCTAssertEqual(WorkspaceCommand.search(model.workspaceCommands, query: "thuoc do").first?.id, "tool.ruler")
        XCTAssertEqual(WorkspaceCommand.search(model.workspaceCommands, query: "lấy màu").first?.id, "tool.sampler")
        XCTAssertEqual(WorkspaceCommand.search(model.workspaceCommands, query: "chup vung").first?.id, "capture.region")
    }
    func testBatchExportBeforeAfterBenchmark() async throws {
        let root = try folder(), input = root.appendingPathComponent("benchmark.png")
        let source = try image(width: 6000, height: 4000); try save(source, input)
        var canvas = CanvasConfiguration(); canvas.showBackground = true
        let start = Date()
        try autoreleasepool {
            let old = try ExportRenderer.render(RenderRequest(image: NSImage(cgImage: source, size: .zero), annotations: [], canvas: canvas, includeBackground: true))
            let cg = try XCTUnwrap(old.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let scale = 600.0 / CGFloat(max(cg.width, cg.height))
            let ctx = try XCTUnwrap(CGContext(data: nil, width: Int(CGFloat(cg.width) * scale), height: Int(CGFloat(cg.height) * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            _ = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(ctx.makeImage())).representation(using: .png, properties: [:]))
        }
        let baseline = Date().timeIntervalSince(start), next = Date()
        _ = try await BatchExportService().export(input, to: root, index: 1, options: BatchExportOptions(canvas: canvas, maxDimension: 600))
        print(String(format: "ISNAP_OPTIMIZATION batch_24mp_to_600_baseline=%.4f bounded=%.4f", baseline, Date().timeIntervalSince(next)))
    }
}
