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
    @Published var r2Connected = false
    @Published var googleDriveConnected = false

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
    private let hotkeys = GlobalHotkeyService()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        document.canvas = settings.value.canvas
        hotkeys.onHotkey = { [weak self] mode in
            Task { await self?.capture(mode) }
        }
        hotkeys.register(settings.value.hotkeys)
        Task {
            r2Connected = await r2Uploader.isConfigured(settings.value.cloud.r2)
            googleDriveConnected = await googleDriveUploader.isConnected()
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
            libraryItems = try await libraryService.items(in: settings.value.quickSave.folder)
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
        } catch { report(error) }
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

    enum CloudProvider { case r2, googleDrive }

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
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            statusText = "Uploaded; link copied"
        } catch { report(error) }
        isUploading = false
    }

    private func accept(_ result: CaptureResult) {
        document.load(result)
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

    private static let uploadTimestamp: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "yyyyMMdd-HHmmss"
        return value
    }()
}
