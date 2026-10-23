import AppKit
import XCTest
import SwiftUI
@testable import iSnap

final class EnhancementTests: XCTestCase {
    func testLegacyWorkflowCloudChoiceIsPreservedButInactive() throws {
        for provider in AppModel.CloudProvider.allCases {
            var workflow = CaptureWorkflow()
            workflow.uploadProvider = provider
            let data = try JSONEncoder().encode(workflow)
            let restored = try JSONDecoder().decode(CaptureWorkflow.self, from: data)
            XCTAssertEqual(restored.uploadProvider, provider)
            XCTAssertNil(restored.activeUploadProvider)
            XCTAssertTrue(restored.saves)
            XCTAssertTrue(restored.copies)
        }
    }

    @MainActor
    func testCloudBacklogHidesRoutesAndBlocksUploadsEvenWithSavedConnectionState() async throws {
        _ = NSApplication.shared
        XCTAssertFalse(SettingsView.Tab.availableCases.contains(.cloud))
        XCTAssertTrue(SettingsView.Tab.availableCases.contains(.export))
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "iSnapCloudBacklog-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            settings: SettingsStore(fileURL: directory.appendingPathComponent("settings.json"), userDefaults: defaults),
            captureLine: CaptureLine(ownedFolder: directory.appendingPathComponent("Line"), defaults: defaults),
            connectsServices: false, features: WorkspaceFeatures(url: directory.appendingPathComponent("workspace.json")))
        model.r2Connected = true
        model.googleDriveConnected = true
        model.docVaultConnected = true
        model.settings.value.cloud.docVault.workspaceID = "previous-workspace"
        let status = model.statusText
        for provider in AppModel.CloudProvider.allCases {
            XCTAssertFalse(model.isAvailable(provider))
            // Return before rendering, reading files or reaching a provider.
            await model.upload(to: provider)
            await model.uploadFile(at: directory.appendingPathComponent("missing.png"), to: provider)
            await model.startUpload(data: Data(), fileExtension: "png", provider: provider)
            do {
                try await model.uploadPayload(Data(), fileExtension: "png", to: provider)
                XCTFail("Cloud payload uploads must be blocked")
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, .featureUnsupported)
            }
        }
        await model.refreshDocVault()
        model.retryData = (Data(), "png", .r2)
        model.retryUpload()
        await Task.yield()
        XCTAssertNil(model.uploadTask)
        XCTAssertFalse(model.isUploading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.statusText, status)
        XCTAssertTrue(model.uploadHistory.isEmpty)
        XCTAssertNotNil(model.retryData)
        let file = directory.appendingPathComponent("capture.png")
        try ProjectStore.png(image()).write(to: file)
        let menu = model.shareMenu(for: file)
        XCTAssertNil(menu.items.first { $0.title == String(localized: "Upload and Copy Link") })
        XCTAssertNotNil(menu.items.first { $0.title == String(localized: "Copy File") })
        XCTAssertNotNil(menu.items.first { $0.title == String(localized: "More Sharing Options") })
    }

    private func image(width: Int = 400, height: Int = 200) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
    }

    private func bitmap(_ image: NSImage) throws -> CGImage {
        try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testPreviewBoundsBitmapAndCachesWithoutChangingExportOrMaskLocation() throws {
        let source = try image()
        var canvas = CanvasConfiguration()
        canvas.cornerRadius = 0; canvas.shadowSize = 0
        let mask = Annotation(type: .redact, frame: CGRect(x: 200, y: 100, width: 160, height: 80))
        let request = RenderRequest(image: source, annotations: [mask], canvas: canvas, includeBackground: true)
        let cache = EditorPreviewCache()
        let preview = try cache.render(request, maxPixelDimension: 100)
        XCTAssertTrue(preview === (try cache.render(request, maxPixelDimension: 100)))
        let small = try bitmap(preview)
        XCTAssertEqual(small.width, 100); XCTAssertEqual(small.height, 50)
        XCTAssertEqual(preview.size, source.size)
        let actual = try pixels(small)
        let direct = try bitmap(ExportRenderer.render(request, maxPixelDimension: 100))
        XCTAssertEqual(actual, try pixels(direct))
        var blackPixels = 0
        for offset in stride(from: 0, to: actual.count, by: 4) {
            let rgbIsBlack = actual[offset] == 0 && actual[offset + 1] == 0 && actual[offset + 2] == 0
            if rgbIsBlack && actual[offset + 3] == 255 { blackPixels += 1 }
        }
        XCTAssertEqual(blackPixels, 800)
        XCTAssertEqual(try bitmap(ExportRenderer.render(request)).width, 400)
        let changed = RenderRequest(image: source, annotations: [], canvas: canvas, includeBackground: true)
        XCTAssertFalse(preview === (try cache.render(changed, maxPixelDimension: 100)))
    }

    @MainActor
    func testMultiSelectionMoveDuplicateAlignReorderAndUndo() throws {
        let doc = EditorDocument()
        doc.load(CaptureResult(image: try image(), sourceName: "Test"))
        let first = Annotation(type: .rectangle, frame: CGRect(x: 10, y: 20, width: 30, height: 40))
        let second = Annotation(type: .arrow, frame: CGRect(x: 80, y: 90, width: 30, height: 40))
        let third = Annotation(type: .ellipse, frame: CGRect(x: 140, y: 30, width: 20, height: 20))
        [first, second, third].forEach(doc.add)
        doc.select(first.id); doc.select(second.id, extending: true)
        doc.moveSelection(dx: 10, dy: -1)
        XCTAssertEqual(doc.annotations[0].frame.origin, CGPoint(x: 20, y: 19))
        XCTAssertEqual(doc.annotations[1].frame.origin, CGPoint(x: 90, y: 89))
        XCTAssertEqual(doc.annotations[2], third)
        doc.undo()
        XCTAssertEqual(doc.annotations, [first, second, third])
        doc.select(first.id); doc.select(second.id, extending: true)
        doc.alignSelection(.top)
        XCTAssertEqual(doc.annotations[1].frame.minY, 20)
        doc.undo()
        doc.select(first.id); doc.select(second.id, extending: true)
        doc.reorderSelection(toFront: true)
        XCTAssertEqual(doc.annotations.map(\.id), [third.id, first.id, second.id])
        doc.duplicateSelection()
        XCTAssertEqual(doc.annotations.count, 5)
        XCTAssertEqual(Set(doc.annotations.map(\.id)).count, 5)
        XCTAssertEqual(doc.selectedAnnotationIDs.count, 2)
        doc.deleteSelection()
        XCTAssertEqual(doc.annotations.count, 3)
        doc.undo()
        XCTAssertEqual(doc.annotations.count, 5)
        doc.undo()
        XCTAssertEqual(doc.annotations.count, 3)
    }

    @MainActor
    func testAutosaveSnapshotIsImmutableAndFinalSaveWinsOverQueuedWrites() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Latest.isnap")
        let doc = EditorDocument()
        doc.load(CaptureResult(image: try image(), sourceName: "Original"))
        let original = try doc.projectSnapshot()
        XCTAssertTrue(original.image === (try doc.projectSnapshot()).image)
        let writer = DraftWriter()
        for _ in 0..<25 { writer.enqueue(original, to: url) { _ in } }
        doc.add(Annotation(type: .text, frame: CGRect(x: 5, y: 5, width: 100, height: 30), text: "Final"))
        try writer.save(doc.projectSnapshot(), to: [url])
        writer.flush()
        let restored = try ProjectStore.read(url)
        XCTAssertEqual(restored.annotations.count, 1)
        XCTAssertEqual(restored.annotations[0].text, "Final")
        XCTAssertTrue(original.project.annotations.isEmpty)
        XCTAssertNotNil(NSImage(data: restored.image))
    }

    @MainActor
    func testDraftWriteFailureDoesNotReplaceRecoverableFile() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Latest.isnap")
        let doc = EditorDocument()
        doc.load(CaptureResult(image: try image(), sourceName: "Recover me"))
        let writer = DraftWriter()
        try writer.save(doc.projectSnapshot(), to: [url])
        let before = try Data(contentsOf: url)
        var broken = try doc.projectSnapshot()
        broken.project.canvas.backgroundImageURL = directory.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try writer.save(broken, to: [url]))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testBulkMetadataAndScopedPruningKeepOtherLibraries() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceFeatures(url: directory.appendingPathComponent("workspace.json"))
        let first = directory.appendingPathComponent("a.png"), second = directory.appendingPathComponent("b.png")
        let other = directory.appendingPathComponent("other/c.png")
        store.setMetadata(LibraryMetadata(favorite: true, tags: []), for: first)
        store.setTags(["bug", "UI"], for: [first, second, other])
        store.pruneMetadata(in: directory, keeping: [first])
        XCTAssertTrue(store.metadata(for: first).favorite)
        XCTAssertEqual(store.metadata(for: first).tags, ["bug", "UI"])
        XCTAssertNil(store.state.metadata[second.path])
        XCTAssertEqual(store.metadata(for: other).tags, ["bug", "UI"])
        let reopened = WorkspaceFeatures(url: directory.appendingPathComponent("workspace.json"))
        XCTAssertNil(reopened.state.metadata[second.path])
        store.removeMetadata(for: [first, other])
        XCTAssertTrue(store.state.metadata.isEmpty)
    }

    func testOCRPruningPersistsAndKeepsOtherLibraries() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.json")
        let kept = directory.appendingPathComponent("keep.png")
        let removed = directory.appendingPathComponent("deleted.png")
        let other = directory.appendingPathComponent("other/image.png")
        let entry = IndexedScreenshot(modifiedAt: Date(), byteCount: 10, text: "private text")
        try JSONEncoder().encode([kept.path: entry, removed.path: entry, other.path: entry]).write(to: url)
        let index = LibrarySearchIndex(url: url)
        try await index.prune(in: directory, keeping: [kept])
        let saved = try JSONDecoder().decode([String: IndexedScreenshot].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(saved.keys), [kept.path, other.path])
        try await index.prune(in: directory, keeping: [])
        let emptyLibrary = try JSONDecoder().decode([String: IndexedScreenshot].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(emptyLibrary.keys), [other.path])
    }

    func testLibrarySelectionSortingAndVietnameseSearchSnippet() {
        let urls = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/tmp/\($0).png") }
        XCTAssertEqual(LibraryNavigation.range(from: urls[2], to: urls[0], in: urls), Set(urls[0...2]))
        XCTAssertEqual(LibraryNavigation.range(from: nil, to: urls[1], in: urls), [urls[1]])
        let items = urls.enumerated().map {
            LibraryItem(url: $0.element, modifiedAt: Date(timeIntervalSince1970: Double($0.offset)),
                dimensions: CGSize(width: $0.offset + 1, height: 10), byteCount: $0.offset * 100)
        }
        XCTAssertEqual(LibrarySort.fileSize.sorted(items).first?.url, urls.last)
        XCTAssertEqual(LibrarySort.oldest.sorted(items).first?.url, urls.first)
        XCTAssertEqual(LibrarySort.dimensions.sorted(items).first?.url, urls.last)
        XCTAssertNotNil(LibraryNavigation.snippet("Đơn hàng thanh toán thành công", query: "thanh toan"))
        XCTAssertNil(LibraryNavigation.snippet("No match", query: "invoice"))
    }

    @MainActor
    func testDraftCatalogRenameAndRecoveryExclusion() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = EditorDocument()
        doc.load(CaptureResult(image: try image(), sourceName: "Old"))
        let old = directory.appendingPathComponent("Old-\(UUID()).isnap")
        try ProjectStore.write(doc.project(), to: old)
        let latest = directory.appendingPathComponent("Latest.isnap")
        try ProjectStore.write(doc.project(), to: latest)
        let catalog = DraftCatalog()
        try await catalog.rename(old, to: "New/name")
        let items = try await catalog.items(in: directory)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "New-name")
        XCTAssertEqual(try ProjectStore.read(XCTUnwrap(items.first?.url)).sourceName, "New-name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: latest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try await catalog.prune(days: 0, directory: directory)
        let unchanged = try await catalog.items(in: directory)
        XCTAssertEqual(unchanged.count, 1)
    }

    func testFixedHeaderTrimmingAndSeamDetail() throws {
        let cg = try bitmap(image(width: 200, height: 400))
        let trimmed = try ScrollingStitcher.trim(cg, top: 40, bottom: 20)
        XCTAssertEqual(trimmed.height, 340)
        XCTAssertThrowsError(try ScrollingStitcher.trim(cg, top: 390, bottom: 20))
        XCTAssertThrowsError(try ScrollingStitcher.trim(cg, top: -1, bottom: 0))
        let seam = try ScrollingStitcher.seam(previous: trimmed, next: trimmed, overlap: 100)
        XCTAssertEqual(seam.width, 200); XCTAssertEqual(seam.height, 160)
        XCTAssertThrowsError(try ScrollingStitcher.seam(previous: trimmed, next: trimmed, overlap: 340))
    }

    @MainActor
    func testRenderEnhancedWorkspace() async throws {
        guard let path = ProcessInfo.processInfo.environment["ISNAP_ENHANCEMENT_SHOTS"] else {
            throw XCTSkip("Set ISNAP_ENHANCEMENT_SHOTS to render the enhanced workspace")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "iSnapEnhancements-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"), userDefaults: defaults)
        let library = directory.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        settings.value.quickSave.folder = library
        let model = AppModel(settings: settings,
            captureLine: CaptureLine(ownedFolder: directory.appendingPathComponent("Line"), defaults: defaults),
            connectsServices: false, features: WorkspaceFeatures(url: directory.appendingPathComponent("workspace.json")))
        model.document.load(CaptureResult(image: try image(width: 1600, height: 900), sourceName: "Workspace review"))
        model.document.add(Annotation(type: .text, frame: CGRect(x: 100, y: 100, width: 1300, height: 110),
            stroke: RGBAColor(.black), text: "iSnap · Workspace improvements", fontSize: 66))
        for (index, label) in ["Group selection", "Background autosave", "Quick Look"].enumerated() {
            model.document.add(Annotation(type: .rectangle,
                frame: CGRect(x: 120 + index * 460, y: 340, width: 400, height: 260),
                stroke: RGBAColor(.systemBlue), fill: RGBAColor(.systemBlue.withAlphaComponent(0.12)), cornerRadius: 16))
            model.document.add(Annotation(type: .text,
                frame: CGRect(x: 130 + index * 460, y: 425, width: 380, height: 70),
                stroke: RGBAColor(.black), text: label, fontSize: 30))
        }
        model.document.canvas.showBackground = true
        model.document.selectAllAnnotations()
        let export = try ExportRenderer.render(RenderRequest(image: try XCTUnwrap(model.document.image),
            annotations: model.document.annotations, canvas: model.document.canvas, includeBackground: true))
        for name in ["Bug report", "Design review", "Release notes", "Team update", "Reference"] {
            try ProjectStore.png(export).write(to: library.appendingPathComponent("\(name).png"))
        }
        let drafts = directory.appendingPathComponent("Drafts")
        try ProjectStore.write(model.document.project(), to: drafts.appendingPathComponent("Workspace review.isnap"))
        await model.reloadLibrary()
        try await render(CommandPaletteView(document: model.document).environmentObject(model),
            to: output.appendingPathComponent("command-palette.png"), size: CGSize(width: 560, height: 420))
        try await render(DuplicateFilesView().environmentObject(model),
            to: output.appendingPathComponent("duplicates.png"), size: CGSize(width: 740, height: 540))
        try await render(ContentView().environmentObject(model), to: output.appendingPathComponent("editor.png"),
            size: CGSize(width: 940, height: 680))
        try await render(ContentView().environmentObject(model), to: output.appendingPathComponent("editor-wide-inspector.png"),
            size: CGSize(width: 1200, height: 820), configure: { host in
                @MainActor func editorSplit(in view: NSView) -> NSSplitView? {
                    if let split = view as? NSSplitView, split.identifier?.rawValue == "iSnap.editorSplit" { return split }
                    for child in view.subviews {
                        if let split = editorSplit(in: child) { return split }
                    }
                    return nil
                }
                let split = try XCTUnwrap(editorSplit(in: host))
                XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.last).frame.width, 280, accuracy: 2)
                split.setPosition(split.bounds.width - 420 - split.dividerThickness, ofDividerAt: 0)
                split.adjustSubviews()
                split.layoutSubtreeIfNeeded()
                XCTAssertEqual(try XCTUnwrap(split.arrangedSubviews.last).frame.width, 420, accuracy: 2)
            })
        try await render(CompositionView(pages: [CompositionPage(url: library.appendingPathComponent("Bug report.png"), caption: "Report")]).environmentObject(model),
            to: output.appendingPathComponent("composition.png"), size: CGSize(width: 800, height: 520))
        try await render(ImageComparisonView(urls: [library.appendingPathComponent("Bug report.png"), library.appendingPathComponent("Design review.png")]),
            to: output.appendingPathComponent("comparison.png"), size: CGSize(width: 1000, height: 680))
        try await render(CutOutView(document: model.document), to: output.appendingPathComponent("cut-out.png"), size: CGSize(width: 640, height: 580))
        model.redactionSource = model.document.image
        model.redactionRegions = [RecognizedRegion(text: "customer@example.com", rect: CGRect(x: 100, y: 100, width: 700, height: 70))]
        try await render(RedactionReviewView().environmentObject(model), to: output.appendingPathComponent("redactions.png"), size: CGSize(width: 880, height: 600))
        let guide = GuideController(directory: library)
        guide.draft = GuideDraft(title: "Report a UI issue", steps: [GuideStep(filename: "Bug report.png", caption: "Open the affected screen"), GuideStep(filename: "Design review.png", caption: "Describe the difference")])
        try await render(GuideView(controller: guide), to: output.appendingPathComponent("guide.png"), size: CGSize(width: 780, height: 600))
        model.features.state.workflows = [CaptureWorkflow()]
        try await render(WorkflowsView().environmentObject(model), to: output.appendingPathComponent("workflows.png"),
            size: CGSize(width: 790, height: 570))
        let regions = [RecognizedRegion(text: "iSnap · Workspace improvements", rect: CGRect(x: 100, y: 100, width: 1300, height: 110)),
            RecognizedRegion(text: "Group selection", rect: CGRect(x: 130, y: 425, width: 380, height: 70))]
        try await render(ScreenshotParseView(text: .constant("iSnap · Workspace improvements\nGroup selection"), sourceName: "Test",
            image: try ExportRenderer.render(RenderRequest(image: try XCTUnwrap(model.document.image), annotations: model.document.annotations, canvas: model.document.canvas, includeBackground: false)), regions: regions), to: output.appendingPathComponent("ocr.png"), size: CGSize(width: 740, height: 690))
        model.section = .library
        try await render(ContentView().environmentObject(model), to: output.appendingPathComponent("library.png"),
            size: CGSize(width: 940, height: 680))
        try await render(DraftsView(directory: drafts).environmentObject(model), to: output.appendingPathComponent("drafts.png"),
            size: CGSize(width: 720, height: 520))
        let emptyLibrary = directory.appendingPathComponent("Empty Library")
        model.settingsTab = .cloud
        try await render(SettingsView(store: settings).environmentObject(model),
            to: output.appendingPathComponent("settings.png"), size: CGSize(width: 740, height: 560))
        XCTAssertEqual(model.settingsTab, .hotkeys)
        try FileManager.default.createDirectory(at: emptyLibrary, withIntermediateDirectories: true)
        model.settings.value.quickSave.folder = emptyLibrary
        await model.reloadLibrary()
        try await render(ContentView().environmentObject(model), to: output.appendingPathComponent("library-empty-compact.png"),
            size: CGSize(width: 940, height: 680))
        try await render(ContentView().environmentObject(model), to: output.appendingPathComponent("library-empty-large.png"),
            size: CGSize(width: 1200, height: 820))
    }

    @MainActor
    private func render<V: View>(_ view: V, to url: URL, size: CGSize, configure: (@MainActor (NSView) throws -> Void)? = nil) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        try configure?(host)
        if configure != nil {
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
        }
        host.display()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
