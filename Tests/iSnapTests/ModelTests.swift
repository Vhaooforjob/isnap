import XCTest
@testable import iSnap

final class ModelTests: XCTestCase {
    func testOutputRatios() {
        XCTAssertNil(OutputRatio.automatic.value)
        XCTAssertEqual(OutputRatio.ratio16x9.value!, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(OutputRatio.ratio9x16.value!, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testBackgroundIsDisabledByDefault() {
        XCTAssertFalse(CanvasConfiguration().showBackground)
    }

    func testAnnotationNormalizesReverseDrag() {
        let item = Annotation(
            type: .rectangle,
            frame: CGRect(x: 100, y: 80, width: -40, height: -30)
        )
        XCTAssertEqual(item.normalizedFrame, CGRect(x: 60, y: 50, width: 40, height: 30))
    }

    func testArrowPreservesDirectionWhenDraggedUpAndLeft() {
        var item = Annotation.make(
            type: .arrow,
            from: CGPoint(x: 180, y: 140),
            to: CGPoint(x: 40, y: 25),
            style: AnnotationStyle()
        )
        XCTAssertEqual(item.lineStartPoint, CGPoint(x: 180, y: 140))
        XCTAssertEqual(item.lineEndPoint, CGPoint(x: 40, y: 25))

        item.setLineEndpoints(start: CGPoint(x: 210, y: 170), end: CGPoint(x: 30, y: 10))
        XCTAssertEqual(item.lineStartPoint, CGPoint(x: 210, y: 170))
        XCTAssertEqual(item.lineEndPoint, CGPoint(x: 30, y: 10))
        XCTAssertEqual(item.normalizedFrame, CGRect(x: 30, y: 10, width: 180, height: 160))
    }

    func testPreviewZoomIsClampedAndReset() async {
        await MainActor.run {
            let document = EditorDocument()
            document.setPreviewZoom(10)
            XCTAssertEqual(document.previewZoom, 4)
            document.setPreviewZoom(0.01)
            XCTAssertEqual(document.previewZoom, 0.25)
            document.resetPreviewZoom()
            XCTAssertEqual(document.previewZoom, 1)
        }
    }

    func testTextToolCreatesPopupEditorRequest() async {
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
            document.load(CaptureResult(
                image: NSImage(cgImage: cgImage, size: CGSize(width: 100, height: 80)),
                sourceName: "Fixture"
            ))
            document.tool = .text

            let canvas = InteractiveCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            canvas.document = document
            let window = NSWindow(
                contentRect: canvas.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = canvas
            let location = CGPoint(x: 400, y: 300)
            guard let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ), let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: location,
                modifierFlags: [],
                timestamp: 0.1,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            ) else {
                XCTFail("Could not create mouse events")
                return
            }

            canvas.mouseDown(with: mouseDown)
            canvas.mouseUp(with: mouseUp)

            XCTAssertEqual(document.annotations.count, 1)
            XCTAssertEqual(document.annotations.first?.type, .text)
            XCTAssertEqual(document.annotationEditRequest?.id, document.annotations.first?.id)
            XCTAssertFalse(document.annotationEditRequest?.checkpointOnCommit ?? true)
        }
    }

    func testMarkerSupportsNumericAndAlphabeticLabels() {
        var marker = Annotation(type: .number, frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        marker.number = 1
        XCTAssertEqual(marker.markerLabel, "1")
        marker.markerStyle = .uppercaseLetter
        XCTAssertEqual(marker.markerLabel, "A")
        marker.number = 27
        XCTAssertEqual(marker.markerLabel, "AA")
        marker.markerStyle = .lowercaseLetter
        XCTAssertEqual(marker.markerLabel, "aa")
    }

    func testEditedMarkerValueControlsNextAutomaticMarker() async {
        await MainActor.run {
            let document = EditorDocument()
            var first = Annotation(type: .number, frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            document.add(first)
            XCTAssertEqual(document.selectedAnnotation?.number, 1)

            guard let inserted = document.selectedAnnotation else {
                XCTFail("Marker was not inserted")
                return
            }
            document.presentEditor(for: inserted)
            first = inserted
            first.number = 7
            first.markerStyle = .uppercaseLetter
            document.commitEditor(first)
            XCTAssertEqual(document.selectedAnnotation?.markerLabel, "G")

            let second = Annotation.make(
                type: .number,
                from: CGPoint(x: 50, y: 50),
                to: CGPoint(x: 90, y: 90),
                style: document.style
            )
            document.add(second)
            XCTAssertEqual(document.selectedAnnotation?.number, 8)
            XCTAssertEqual(document.selectedAnnotation?.markerLabel, "H")
        }
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

    func testEditorShortcutParser() {
        let save = EditorKeyboardShortcut.parse("⌘S")
        XCTAssertEqual(save?.key.character, "s")
        XCTAssertTrue(save?.modifiers.contains(.command) == true)

        let customCopy = EditorKeyboardShortcut.parse("⌃⌥K")
        XCTAssertEqual(customCopy?.key.character, "k")
        XCTAssertTrue(customCopy?.modifiers.contains(.control) == true)
        XCTAssertTrue(customCopy?.modifiers.contains(.option) == true)
    }

    func testLegacyHotkeySettingsReceiveEditorShortcutDefaults() throws {
        let data = Data(#"{"fullScreen":"⌃⌥1","region":"⌃⌥2","window":"⌃⌥3"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.HotkeySettings.self, from: data)
        XCTAssertEqual(decoded.saveEditedImage, "⌘S")
        XCTAssertEqual(decoded.copyEditedImage, "⌘C")
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.export.defaultFormat = .jpeg
        settings.canvas.outputRatio = .square
        settings.cloud.r2.bucket = "screenshots"
        settings.hotkeys.saveEditedImage = "⌘⇧K"
        settings.hotkeys.copyEditedImage = "⌃⌥C"
        settings.canvas.watermark = WatermarkConfiguration(
            kind: .image,
            text: "Internal",
            imageData: Data([1, 2, 3]),
            opacity: 0.42,
            placement: .tiled,
            sizePercent: 22,
            textColor: .red
        )
        settings.backgroundImages = [URL(fileURLWithPath: "/tmp/background.jpg")]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testImageOverlayAndWatermarkUseFinalRenderer() async throws {
        try await MainActor.run {
            func makeImage(color: NSColor, size: CGSize) throws -> (NSImage, Data) {
                guard let context = CGContext(
                    data: nil,
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { throw ExportError.invalidImage }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                guard let cgImage = context.makeImage(),
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    throw ExportError.encodingFailed
                }
                return (NSImage(cgImage: cgImage, size: size), data)
            }

            func centerColor(_ image: NSImage) throws -> NSColor {
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let color = NSBitmapImageRep(cgImage: cgImage)
                        .colorAt(x: cgImage.width / 2, y: cgImage.height / 2)?
                        .usingColorSpace(.sRGB) else {
                    throw ExportError.invalidImage
                }
                return color
            }

            func matchingPixelCount(_ image: NSImage, predicate: (NSColor) -> Bool) throws -> Int {
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw ExportError.invalidImage
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                var count = 0
                for y in 0..<cgImage.height {
                    for x in 0..<cgImage.width {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), predicate(color) {
                            count += 1
                        }
                    }
                }
                return count
            }

            let (base, _) = try makeImage(color: .white, size: CGSize(width: 100, height: 100))
            let (_, redData) = try makeImage(color: .red, size: CGSize(width: 20, height: 20))
            var canvas = CanvasConfiguration()
            canvas.cornerRadius = 0
            canvas.shadowSize = 0

            var overlay = Annotation(type: .image, frame: CGRect(x: 25, y: 25, width: 50, height: 50))
            overlay.imageData = redData
            overlay.imageOpacity = 0.5
            let overlayResult = try ExportRenderer.render(RenderRequest(
                image: base,
                annotations: [overlay],
                canvas: canvas,
                includeBackground: true
            ))
            let blended = try centerColor(overlayResult)
            XCTAssertGreaterThan(blended.redComponent, 0.9)
            XCTAssertEqual(blended.greenComponent, 0.5, accuracy: 0.12)

            canvas.watermark = WatermarkConfiguration(
                kind: .image,
                text: "",
                imageData: redData,
                opacity: 1,
                placement: .center,
                sizePercent: 30,
                textColor: .white
            )
            let watermarkResult = try ExportRenderer.render(RenderRequest(
                image: base,
                annotations: [],
                canvas: canvas,
                includeBackground: true
            ))
            let watermarked = try centerColor(watermarkResult)
            XCTAssertGreaterThan(watermarked.redComponent, 0.9)
            XCTAssertLessThan(watermarked.greenComponent, 0.1)

            canvas.watermark = WatermarkConfiguration(
                kind: .text,
                text: "CONFIDENTIAL",
                imageData: nil,
                opacity: 1,
                placement: .center,
                sizePercent: 40,
                textColor: RGBAColor(.black)
            )
            let textResult = try ExportRenderer.render(RenderRequest(
                image: base,
                annotations: [],
                canvas: canvas,
                includeBackground: true
            ))
            let darkTextPixels = try matchingPixelCount(textResult) {
                $0.redComponent < 0.7 && $0.greenComponent < 0.7 && $0.blueComponent < 0.7
            }
            XCTAssertGreaterThan(darkTextPixels, 20)

            canvas.watermark = WatermarkConfiguration(
                kind: .image,
                text: "",
                imageData: redData,
                opacity: 1,
                placement: .tiled,
                sizePercent: 10,
                textColor: .white
            )
            let tiledResult = try ExportRenderer.render(RenderRequest(
                image: base,
                annotations: [],
                canvas: canvas,
                includeBackground: true
            ))
            let tiledRedPixels = try matchingPixelCount(tiledResult) {
                $0.redComponent > 0.9 && $0.greenComponent < 0.1 && $0.blueComponent < 0.1
            }
            XCTAssertGreaterThan(tiledRedPixels, 250)
            XCTAssertEqual(WatermarkPlacement.allCases.count, 10)
        }
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
