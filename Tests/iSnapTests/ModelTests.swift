import XCTest
@testable import iSnap

final class ModelTests: XCTestCase {
    func testOutputRatios() {
        XCTAssertNil(OutputRatio.automatic.value)
        XCTAssertEqual(OutputRatio.ratio16x9.value!, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(OutputRatio.ratio9x16.value!, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testAnnotationNormalizesReverseDrag() {
        let item = Annotation(
            type: .rectangle,
            frame: CGRect(x: 100, y: 80, width: -40, height: -30)
        )
        XCTAssertEqual(item.normalizedFrame, CGRect(x: 60, y: 50, width: 40, height: 30))
    }

    func testHotkeyParser() async {
        let shortcut = await MainActor.run { GlobalHotkeyService.parse("⌃⌥2") }
        XCTAssertEqual(shortcut?.keyCode, 19)
        XCTAssertNotEqual(shortcut?.modifiers, 0)
        let functionKey = await MainActor.run { GlobalHotkeyService.parse("⌃⌥F12") }
        XCTAssertEqual(functionKey?.keyCode, 111)
        let punctuationKey = await MainActor.run { GlobalHotkeyService.parse("⌃⌥.") }
        XCTAssertEqual(punctuationKey?.keyCode, 47)
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.export.defaultFormat = .jpeg
        settings.canvas.outputRatio = .square
        settings.cloud.r2.bucket = "screenshots"
        settings.backgroundImages = [URL(fileURLWithPath: "/tmp/background.jpg")]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testCropUndoRestoresOriginalBitmap() async {
        await MainActor.run {
            guard let context = CGContext(
                data: nil,
                width: 100,
                height: 80,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = context.makeImage() else {
                XCTFail("Could not create fixture image")
                return
            }
            let document = EditorDocument()
            document.load(CaptureResult(image: NSImage(cgImage: cgImage, size: CGSize(width: 100, height: 80)), sourceName: "Fixture"))
            document.cropRect = CGRect(x: 10, y: 10, width: 40, height: 30)
            document.applyCrop()
            XCTAssertEqual(document.imagePixelSize, CGSize(width: 40, height: 30))
            document.undo()
            XCTAssertEqual(document.imagePixelSize, CGSize(width: 100, height: 80))
            XCTAssertFalse(document.isCropApplied)
        }
    }

    func testLegacyQuickSaveSettingsEnableLibraryArchiving() throws {
        let data = Data(#"{"folder":"file:\/\/\/tmp\/iSnap","pattern":"timestamp"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.QuickSaveSettings.self, from: data)
        XCTAssertTrue(decoded.autoSaveCaptures)
    }

    func testArchiveCapturePreservesPixelDimensions() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("iSnapTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let context = CGContext(
                data: nil,
                width: 100,
                height: 80,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = context.makeImage() else {
                XCTFail("Could not create fixture image")
                return
            }
            var settings = AppSettings()
            settings.quickSave.folder = folder
            let url = try ExportService().archiveCapture(
                NSImage(cgImage: cgImage, size: CGSize(width: 100, height: 80)),
                settings: settings
            )
            guard let saved = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                XCTFail("Could not decode archived capture")
                return
            }
            XCTAssertEqual(saved.pixelsWide, 100)
            XCTAssertEqual(saved.pixelsHigh, 80)
        }
    }
}
