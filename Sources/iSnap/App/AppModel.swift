import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case library = "Library"
        var id: String { rawValue }
        var symbol: String { self == .editor ? "photo.on.rectangle.angled" : "photo.stack" }
    }

    @Published var section = Section.editor
    @Published var isCapturing = false
    @Published var statusText = "Ready"
    @Published var errorMessage: String?
    @Published var isShowingScreenRecordingRecovery = false
    @Published var isShowingSettings = false
    @Published var isShowingWindowPicker = false
    @Published var availableWindows: [CapturableWindow] = []
    @Published var libraryItems: [LibraryItem] = []
    @Published var releaseInfo: ReleaseInfo?
    @Published var isUploading = false
    @Published var isParsingScreenshot = false
    @Published var isShowingParsedData = false
    @Published var recognizedText = ""
    @Published var recognizedSourceName = "Screenshot"
    @Published var r2Connected = false
    @Published var googleDriveConnected = false
    @Published var docVaultConnected = false
    @Published var docVaultUser: DocVaultUser?
    @Published var docVaultWorkspaces: [DocVaultWorkspace] = []
    @Published var docVaultAccounts: [DocVaultStorageAccount] = []
    @Published var isRefreshingDocVault = false

    let document = EditorDocument()
    let settings = SettingsStore()
    var presentMainWindow: (() -> Void)?

    private let captureService = CaptureService()
    private let regionCoordinator = RegionCaptureCoordinator()
    private let exportService = ExportService()
    private let libraryService = LibraryService()
    private let updateService = UpdateService()
    private let r2Uploader = R2Uploader()
    private let googleDriveUploader = GoogleDriveUploader()
    private let docVaultService = DocVaultService()
    private let screenshotParser = ScreenshotParserService()
    private let hotkeys = GlobalHotkeyService()
    private var cancellables: Set<AnyCancellable> = []
    private var widgetPublishTask: Task<Void, Never>?

    init() {
        document.canvas = settings.value.canvas
        hotkeys.onHotkey = { [weak self] mode in
            Task { await self?.capture(mode) }
        }
        hotkeys.register(settings.value.hotkeys)
        Task {
            r2Connected = await r2Uploader.isConfigured(settings.value.cloud.r2)
            googleDriveConnected = await googleDriveUploader.isConnected()
            docVaultConnected = await docVaultService.isConnected(config: settings.value.cloud.docVault)
            if docVaultConnected { await refreshDocVault(showError: false) }
        }
        settings.$value
            .dropFirst()
            .sink { [weak self] value in
                self?.hotkeys.register(value.hotkeys)
            }
            .store(in: &cancellables)
    }

    func capture(_ mode: CaptureMode) async {
        guard !isCapturing else { return }
        if mode == .window {
            await loadWindows()
            return
        }
        isCapturing = true
        statusText = "Capturing…"
        do {
            let result: CaptureResult
            switch mode {
            case .fullScreen:
                NSApp.hide(nil)
                try await Task.sleep(for: .milliseconds(180))
                result = try await captureService.captureAllDisplays()
                NSApp.unhide(nil)
            case .region:
                let visibleWindows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
                visibleWindows.forEach { $0.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(120))
                do {
                    guard let selection = await regionCoordinator.selectRegion() else {
                        throw CaptureError.cancelled
                    }
                    result = try await captureService.capture(displayID: selection.displayID, region: selection.rect)
                } catch {
                    visibleWindows.forEach { $0.makeKeyAndOrderFront(nil) }
                    throw error
                }
                visibleWindows.forEach { $0.makeKeyAndOrderFront(nil) }
            case .window:
                throw CaptureError.cancelled
            }
            accept(result)
        } catch CaptureError.cancelled {
            statusText = "Capture cancelled"
        } catch {
            NSApp.unhide(nil)
            report(error)
        }
        isCapturing = false
    }

    func loadWindows() async {
        isCapturing = true
        statusText = "Loading windows…"
        do {
            availableWindows = try await captureService.windows()
            isShowingWindowPicker = true
            statusText = "Choose a window"
            presentMainWindow?()
        } catch { report(error) }
        isCapturing = false
    }

    func capture(window: CapturableWindow) async {
        isShowingWindowPicker = false
        isCapturing = true
        do {
            NSApp.hide(nil)
            try await Task.sleep(for: .milliseconds(150))
            let result = try await captureService.capture(windowID: window.id)
            NSApp.unhide(nil)
            accept(result)
        } catch {
            NSApp.unhide(nil)
            report(error)
        }
        isCapturing = false
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        accept(CaptureResult(image: image, sourceName: url.lastPathComponent))
    }

    func pasteImage() {
        guard let image = NSImage(pasteboard: .general) else {
            errorMessage = "The clipboard does not contain an image."
            return
        }
        accept(CaptureResult(image: image, sourceName: "Clipboard"))
    }

    func parseScreenshot() async {
        guard !isParsingScreenshot, let image = document.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            if document.image == nil { errorMessage = "Capture or open an image before extracting text." }
            return
        }
        isParsingScreenshot = true
        statusText = "Extracting text with macOS Vision…"
        defer { isParsingScreenshot = false }

        do {
            let result = try await screenshotParser.parse(cgImage)
            guard document.image === image else { return }
            recognizedText = result.text
            recognizedSourceName = document.sourceName
            isShowingParsedData = true
            statusText = result.lineCount == 0
                ? "No text detected"
                : "Extracted \(result.lineCount) text \(result.lineCount == 1 ? "line" : "lines")"
            presentMainWindow?()
        } catch is CancellationError {
            statusText = "Text extraction cancelled"
        } catch {
            report(error)
        }
    }

    func insertOverlayImage() {
        guard document.image != nil else {
            errorMessage = "Capture or open an image before inserting an overlay."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BackgroundImageStore.portableImageData(from: url)
            guard let image = NSImage(data: data),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ExportError.invalidImage
            }
            let sourceSize = document.imagePixelSize
            let intrinsicSize = CGSize(width: cgImage.width, height: cgImage.height)
            let scale = min(
                sourceSize.width * 0.35 / intrinsicSize.width,
                sourceSize.height * 0.35 / intrinsicSize.height
            )
            let size = CGSize(
                width: max(24, intrinsicSize.width * scale),
                height: max(24, intrinsicSize.height * scale)
            )
            var annotation = Annotation(
                type: .image,
                frame: CGRect(
                    x: (sourceSize.width - size.width) / 2,
                    y: (sourceSize.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            )
            annotation.imageData = data
            annotation.imageOpacity = 1
            document.add(annotation)
            statusText = "Inserted \(url.lastPathComponent)"
        } catch { report(error) }
    }

    func insertSticker(_ sticker: StickerPreset) {
        guard document.image != nil else {
            errorMessage = "Capture or open an image before adding a sticker."
            return
        }
        do {
            let data = try StickerRenderer.pngData(for: sticker.emoji)
            let sourceSize = document.imagePixelSize
            let side = min(240, max(32, min(sourceSize.width, sourceSize.height) * 0.22))
            var annotation = Annotation(
                type: .image,
                frame: CGRect(
                    x: (sourceSize.width - side) / 2,
                    y: (sourceSize.height - side) / 2,
                    width: side,
                    height: side
                )
            )
            annotation.imageData = data
            annotation.imageOpacity = 1
            document.add(annotation)
            statusText = "Added \(sticker.name) sticker"
        } catch { report(error) }
    }

    func quickSave() {
        do {
            settings.value.canvas = document.canvas
            let url = try exportService.quickSave(document: document, settings: settings.value)
            statusText = "Saved \(url.lastPathComponent)"
            Task { await reloadLibrary() }
        } catch { report(error) }
    }

    func saveAs() {
        do {
            settings.value.canvas = document.canvas
            if let url = try exportService.saveAs(document: document, settings: settings.value) {
                statusText = "Exported \(url.lastPathComponent)"
            }
        } catch { report(error) }
    }

    func copy() {
        do {
            try exportService.copy(document: document, includeBackground: settings.value.export.includeBackground)
            statusText = "Copied to clipboard"
        } catch { report(error) }
    }

    func reloadLibrary() async {
        do {
            try FileManager.default.createDirectory(at: settings.value.quickSave.folder, withIntermediateDirectories: true)
            let items = try await libraryService.items(in: settings.value.quickSave.folder)
            libraryItems = items
            widgetPublishTask?.cancel()
            widgetPublishTask = Task(priority: .utility) { [libraryService] in
                guard !Task.isCancelled else { return }
                await libraryService.publishWidgetSnapshot(items)
            }
        } catch { report(error) }
    }

    func openLibraryItem(_ item: LibraryItem) {
        guard let image = NSImage(contentsOf: item.url) else { return }
        accept(CaptureResult(image: image, sourceName: item.name))
    }

    func deleteLibraryItem(_ item: LibraryItem) async {
        do {
            try await libraryService.delete(item, rootFolder: settings.value.quickSave.folder)
            await reloadLibrary()
            statusText = "Moved \(item.name) to Trash"
        } catch { report(error) }
    }

    func deleteAllLibraryItems() async {
        do {
            let count = try await libraryService.deleteAll(in: settings.value.quickSave.folder)
            await reloadLibrary()
            statusText = count == 1 ? "Moved 1 screenshot to Trash" : "Moved \(count) screenshots to Trash"
        } catch {
            await reloadLibrary()
            report(error)
        }
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([settings.value.quickSave.folder])
    }

    func checkForUpdates() async {
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            if let release = try await updateService.latestRelease(currentVersion: version),
               release.tagName != settings.value.update.skippedVersion {
                releaseInfo = release
            }
        } catch {
            statusText = "Could not check for updates"
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"$1\"",
            "isnap-restart",
            Bundle.main.bundleURL.path
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            report(error)
        }
    }

    func configureR2(accessKeyID: String, secretAccessKey: String) async {
        do {
            try await r2Uploader.saveCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            statusText = "Testing Cloudflare R2…"
            try await r2Uploader.test(settings.value.cloud.r2)
            r2Connected = true
            statusText = "Cloudflare R2 connected"
        } catch {
            r2Connected = false
            report(error)
        }
    }

    func connectGoogleDrive(clientID: String, clientSecret: String) async {
        do {
            try await googleDriveUploader.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            statusText = "Waiting for Google authorization…"
            try await googleDriveUploader.authorize()
            googleDriveConnected = true
            statusText = "Google Drive connected"
        } catch { report(error) }
    }

    func disconnectGoogleDrive() async {
        do {
            try await googleDriveUploader.disconnect()
            googleDriveConnected = false
            statusText = "Google Drive disconnected"
        } catch { report(error) }
    }

    var defaultDocVaultAccount: DocVaultStorageAccount? {
        docVaultAccounts.first(where: { $0.isDefaultStorage })
    }

    func connectDocVault() async {
        guard !isRefreshingDocVault else { return }
        isRefreshingDocVault = true
        statusText = "Waiting for DocVault sign-in…"
        defer { isRefreshingDocVault = false }
        do {
            let snapshot = try await docVaultService.connect(config: settings.value.cloud.docVault)
            applyDocVault(snapshot)
            docVaultConnected = true
            statusText = "DocVault connected"
        } catch { report(error) }
    }

    func disconnectDocVault() async {
        do {
            try await docVaultService.disconnect(config: settings.value.cloud.docVault)
            docVaultConnected = false
            docVaultUser = nil
            docVaultWorkspaces = []
            docVaultAccounts = []
            statusText = "DocVault disconnected"
        } catch { report(error) }
    }

    func refreshDocVault(showError: Bool = true) async {
        guard !isRefreshingDocVault else { return }
        isRefreshingDocVault = true
        defer { isRefreshingDocVault = false }
        do {
            let snapshot = try await docVaultService.snapshot(config: settings.value.cloud.docVault)
            applyDocVault(snapshot)
            docVaultConnected = true
        } catch {
            docVaultConnected = await docVaultService.isConnected(config: settings.value.cloud.docVault)
            if showError { report(error) }
        }
    }

    func selectDocVaultStorageAccount(_ accountID: String) async {
        do {
            _ = try await docVaultService.setDefaultStorageAccount(accountID, config: settings.value.cloud.docVault)
            await refreshDocVault()
            statusText = "DocVault storage account updated"
        } catch { report(error) }
    }

    enum CloudProvider { case r2, googleDrive, docVault }

    func upload(to provider: CloudProvider) async {
        guard !isUploading else { return }
        isUploading = true
        statusText = "Rendering upload…"
        do {
            let format = settings.value.export.defaultFormat
            let image = try exportService.render(document: document, includeBackground: settings.value.export.includeBackground)
            let data = try exportService.encode(image, format: format, quality: settings.value.export.jpegQuality)
            let filename = "iSnap-\(Self.uploadTimestamp.string(from: Date())).\(format.fileExtension)"
            statusText = "Uploading…"
            let url: URL
            switch provider {
            case .r2:
                url = try await r2Uploader.upload(data, filename: filename, config: settings.value.cloud.r2)
            case .googleDrive:
                url = try await googleDriveUploader.upload(data, filename: filename, folderID: settings.value.cloud.googleDrive.folderID)
            case .docVault:
                url = try await docVaultService.upload(data, filename: filename, config: settings.value.cloud.docVault)
                await refreshDocVault(showError: false)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            statusText = "Uploaded; link copied"
        } catch { report(error) }
        isUploading = false
    }

    private func accept(_ result: CaptureResult) {
        document.load(result)
        recognizedText = ""
        isShowingParsedData = false
        document.canvas = settings.value.canvas
        section = .editor
        statusText = "\(Int(document.imagePixelSize.width)) × \(Int(document.imagePixelSize.height)) px"
        presentMainWindow?()
        if settings.value.quickSave.autoSaveCaptures {
            statusText = "Captured • Saving to Library…"
            Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                do {
                    let archived = try exportService.archiveCapture(result.image, settings: settings.value)
                    statusText = "Captured and saved \(archived.lastPathComponent)"
                    await reloadLibrary()
                } catch {
                    statusText = "Captured • Library save failed"
                }
            }
        }
    }

    private func report(_ error: Error) {
        if let captureError = error as? CaptureError,
           case .permissionDenied = captureError {
            isShowingScreenRecordingRecovery = true
            statusText = "Screen Recording access needs attention"
            return
        }
        errorMessage = error.localizedDescription
        statusText = "Failed"
    }

    private func applyDocVault(_ snapshot: DocVaultSnapshot) {
        docVaultUser = snapshot.user
        docVaultWorkspaces = snapshot.workspaces
        docVaultAccounts = snapshot.storageAccounts
        let configuredWorkspace = settings.value.cloud.docVault.workspaceID
        if !snapshot.workspaces.contains(where: { $0.id == configuredWorkspace }) {
            settings.value.cloud.docVault.workspaceID = snapshot.workspaces.first?.id ?? ""
        }
    }

    private static let uploadTimestamp: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyyMMdd-HHmmss"
        return value
    }()
}

enum StickerRenderer {
    static func pngData(for emoji: String, pixelSize: Int = 256) throws -> Data {
        guard pixelSize > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelSize,
                  pixelsHigh: pixelSize,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bitmapFormat: [.alphaFirst],
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ExportError.encodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        let fontSize = CGFloat(pixelSize) * 0.68
        let font = NSFont(name: "Apple Color Emoji", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let value = NSAttributedString(string: emoji, attributes: [.font: font])
        let size = value.size()
        value.draw(at: CGPoint(
            x: (CGFloat(pixelSize) - size.width) / 2,
            y: (CGFloat(pixelSize) - size.height) / 2
        ))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        return data
    }
}
