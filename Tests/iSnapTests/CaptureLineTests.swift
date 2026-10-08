import AppKit
import XCTest
@testable import iSnap

@MainActor
final class CaptureLineTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSnapCaptureLine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "iSnapCaptureLineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLegacySettingsReceiveCaptureLineDefaults() throws {
        let data = Data(#"{"hotkeys":{"fullScreen":"⌃⌥9","region":"⌃⌥2","window":"⌃⌥3"},"export":{"defaultFormat":"jpeg","jpegQuality":0.8,"includeBackground":false,"autoCopyToClipboard":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.hotkeys.fullScreen, "⌃⌥9")
        XCTAssertEqual(decoded.hotkeys.toggleCaptureLine, "⌃⌥T")
        XCTAssertEqual(decoded.export.defaultFormat, .jpeg)
        XCTAssertEqual(decoded.captureLine, AppSettings.CaptureLineSettings())
        XCTAssertTrue(decoded.captureLine.isEnabled)
        XCTAssertTrue(decoded.captureLine.opensEditorAfterCapture)
        XCTAssertFalse(decoded.captureLine.routesSystemScreenshots)
    }

    func testCaptureLineSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.captureLine.opensEditorAfterCapture = false
        settings.captureLine.routesSystemScreenshots = true
        settings.hotkeys.toggleCaptureLine = "⌃⌥L"
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testToggleShortcutParses() {
        XCTAssertNotNil(GlobalHotkeyService.parse(AppSettings.HotkeySettings().toggleCaptureLine))
    }

    func testHangIgnoresDuplicatesAndUnreadableFiles() throws {
        let line = CaptureLine(ownedFolder: root.appendingPathComponent("Line"), defaults: defaults)
        let url = try fixture("a.png")
        XCTAssertNotNil(line.hang(url, quietly: true))
        XCTAssertNil(line.hang(url, quietly: true))
        XCTAssertNil(line.hang(root.appendingPathComponent("missing.png"), quietly: true))
        XCTAssertEqual(line.liveCount, 1)
    }

    func testFullLineDropsOldestCapture() throws {
        let line = CaptureLine(ownedFolder: root.appendingPathComponent("Line"), defaults: defaults)
        line.maxItems = 3
        let urls = try (0..<4).map { try fixture("capture-\($0).png") }
        urls.forEach { line.hang($0, quietly: true) }
        XCTAssertEqual(line.liveCount, 3)
        let live = line.items.filter { !$0.isFalling }.map(\.url)
        XCTAssertEqual(live, Array(urls.dropFirst()))
    }

    func testLineRestoresExistingCapturesOnly() throws {
        let kept = try fixture("kept.png")
        let removed = try fixture("removed.png")
        do {
            let line = CaptureLine(ownedFolder: root.appendingPathComponent("Line"), defaults: defaults)
            line.hang(kept, quietly: true)
            line.hang(removed, quietly: true)
        }
        try FileManager.default.removeItem(at: removed)
        let restored = CaptureLine(ownedFolder: root.appendingPathComponent("Line"), defaults: defaults)
        XCTAssertEqual(restored.items.map(\.url.path), [kept.path])
    }

    func testOnlyLineFolderCapturesAreOwned() throws {
        let owned = root.appendingPathComponent("Line", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let line = CaptureLine(ownedFolder: owned, defaults: defaults)
        XCTAssertTrue(line.isOwned(owned.appendingPathComponent("shot.png")))
        XCTAssertFalse(line.isOwned(root.appendingPathComponent("shot.png")))
        // A sibling folder sharing the prefix is not the line's folder.
        XCTAssertFalse(line.isOwned(root.appendingPathComponent("LineExtra/shot.png")))
    }

    func testTakingDownALibraryCaptureKeepsTheFile() throws {
        let line = CaptureLine(ownedFolder: root.appendingPathComponent("Line"), defaults: defaults)
        let url = try fixture("library.png")
        let id = try XCTUnwrap(line.hang(url, quietly: true))
        line.discard(id)
        XCTAssertEqual(line.liveCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUniqueURLAvoidsOverwriting() throws {
        let existing = try fixture("shot.png")
        let next = CaptureLine.uniqueURL(in: root, for: existing.lastPathComponent)
        XCTAssertEqual(next.lastPathComponent, "shot 2.png")
    }

    func testLayoutKeepsCardsProportionalAndCapacityBounded() {
        let wide = CaptureLineLayout.photoSize(for: CGSize(width: 1_600, height: 900))
        XCTAssertEqual(wide.width / wide.height, 1_600 / 900, accuracy: 0.001)
        XCTAssertLessThanOrEqual(wide.width, CaptureLineLayout.cardWidth)
        let tall = CaptureLineLayout.photoSize(for: CGSize(width: 400, height: 1_200))
        XCTAssertLessThanOrEqual(tall.height, 104)
        XCTAssertEqual(CaptureLineLayout.capacity(width: 300), 3)
        XCTAssertEqual(CaptureLineLayout.capacity(width: 10_000), 12)
        // The rope sags lowest in the middle.
        XCTAssertGreaterThan(
            CaptureLineLayout.ropeY(x: 720, width: 1_440),
            CaptureLineLayout.ropeY(x: 100, width: 1_440)
        )
    }

    func testLanguageChoiceIsSavedAsAppleLanguagesOverride() {
        XCTAssertEqual(AppLanguage.saved(in: defaults, bundleID: suiteName), .system)
        AppLanguage.save(.vietnamese, in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["vi"])
        XCTAssertEqual(AppLanguage.saved(in: defaults, bundleID: suiteName), .vietnamese)
        AppLanguage.save(.english, in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults, bundleID: suiteName), .english)
        AppLanguage.save(.system, in: defaults)
        XCTAssertEqual(AppLanguage.saved(in: defaults, bundleID: suiteName), .system)
    }

    func testCaptureModesKeepHotkeyOrderAndAddAllDisplays() {
        XCTAssertEqual(CaptureMode.allCases, [.fullScreen, .region, .window, .allDisplays])
        XCTAssertEqual(Set(CaptureMode.allCases.map(\.symbol)).count, CaptureMode.allCases.count)
    }

    func testClipboardScreenshotDetectionAcceptsOnlyBarePNG() {
        XCTAssertTrue(ClipboardScreenshotWatcher.looksLikeScreenshot([[.png]]))
        // iSnap's own card copy adds a file URL; apps add TIFF, HTML and more.
        XCTAssertFalse(ClipboardScreenshotWatcher.looksLikeScreenshot([[.png, .fileURL]]))
        XCTAssertFalse(ClipboardScreenshotWatcher.looksLikeScreenshot([[.tiff, .png]]))
        XCTAssertFalse(ClipboardScreenshotWatcher.looksLikeScreenshot([[.png], [.png]]))
        XCTAssertFalse(ClipboardScreenshotWatcher.looksLikeScreenshot([]))
    }

    func testVisibilityMigratesFromLegacyFlags() throws {
        func decode(_ json: String) throws -> AppSettings.CaptureLineSettings {
            try JSONDecoder().decode(AppSettings.CaptureLineSettings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"revealsFromMenuBar":true}"#).visibility, .onHover)
        XCTAssertEqual(try decode(#"{"keepsVisible":true}"#).visibility, .always)
        XCTAssertEqual(try decode(#"{"revealsFromMenuBar":false}"#).visibility, .hidden)
        XCTAssertEqual(try decode(#"{"visibility":"hidden","keepsVisible":true}"#).visibility, .hidden)
        XCTAssertTrue(try decode("{}").hangsClipboardScreenshots)

        // Only the new key is written back.
        let encoded = try JSONEncoder().encode(try decode(#"{"keepsVisible":true}"#))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["visibility"] as? String, "always")
        XCTAssertNil(object["keepsVisible"])
        XCTAssertNil(object["revealsFromMenuBar"])
    }

    func testMenuShortcutParsingForStatusMenu() {
        let item = NSMenuItem()
        item.showShortcut("⌃⌥1")
        XCTAssertEqual(item.keyEquivalent, "1")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.control, .option])
        item.showShortcut("not a shortcut")
        XCTAssertEqual(item.keyEquivalent, "")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
