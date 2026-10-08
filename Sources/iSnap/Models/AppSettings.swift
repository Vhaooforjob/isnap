import Foundation

struct AppSettings: Codable, Equatable {
    var hotkeys = HotkeySettings()
    var startup = StartupSettings()
    var quickSave = QuickSaveSettings()
    var export = ExportSettings()
    var canvas = CanvasConfiguration()
    var update = UpdateSettings()
    var cloud = CloudSettings()
    var captureLine = CaptureLineSettings()
    var backgroundImages: [URL] = []

    private enum CodingKeys: String, CodingKey {
        case hotkeys, startup, quickSave, export, canvas, update, cloud, captureLine, backgroundImages
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = try values.decodeIfPresent(HotkeySettings.self, forKey: .hotkeys) ?? HotkeySettings()
        startup = try values.decodeIfPresent(StartupSettings.self, forKey: .startup) ?? StartupSettings()
        quickSave = try values.decodeIfPresent(QuickSaveSettings.self, forKey: .quickSave) ?? QuickSaveSettings()
        export = try values.decodeIfPresent(ExportSettings.self, forKey: .export) ?? ExportSettings()
        canvas = try values.decodeIfPresent(CanvasConfiguration.self, forKey: .canvas) ?? CanvasConfiguration()
        update = try values.decodeIfPresent(UpdateSettings.self, forKey: .update) ?? UpdateSettings()
        cloud = try values.decodeIfPresent(CloudSettings.self, forKey: .cloud) ?? CloudSettings()
        captureLine = try values.decodeIfPresent(CaptureLineSettings.self, forKey: .captureLine) ?? CaptureLineSettings()
        backgroundImages = try values.decodeIfPresent([URL].self, forKey: .backgroundImages) ?? []
    }

    struct HotkeySettings: Codable, Equatable {
        var fullScreen = "⌃⌥1"
        var region = "⌃⌥2"
        var window = "⌃⌥3"
        var saveEditedImage = "⌘S"
        var copyEditedImage = "⌘C"
        var toggleCaptureLine = "⌃⌥T"

        private enum CodingKeys: String, CodingKey {
            case fullScreen, region, window, saveEditedImage, copyEditedImage, toggleCaptureLine
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fullScreen = try values.decodeIfPresent(String.self, forKey: .fullScreen) ?? "⌃⌥1"
            region = try values.decodeIfPresent(String.self, forKey: .region) ?? "⌃⌥2"
            window = try values.decodeIfPresent(String.self, forKey: .window) ?? "⌃⌥3"
            saveEditedImage = try values.decodeIfPresent(String.self, forKey: .saveEditedImage) ?? "⌘S"
            copyEditedImage = try values.decodeIfPresent(String.self, forKey: .copyEditedImage) ?? "⌘C"
            toggleCaptureLine = try values.decodeIfPresent(String.self, forKey: .toggleCaptureLine) ?? "⌃⌥T"
        }
    }

    struct StartupSettings: Codable, Equatable {
        var launchAtLogin = false
        var startHidden = false
        var showNotifications = true
        var closeToMenuBar = true
    }

    struct QuickSaveSettings: Codable, Equatable {
        var folder: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSnap", isDirectory: true)
        var pattern = FilenamePattern.timestamp
        var autoSaveCaptures = true

        private enum CodingKeys: String, CodingKey {
            case folder, pattern, autoSaveCaptures
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            folder = try values.decodeIfPresent(URL.self, forKey: .folder) ?? Self().folder
            pattern = try values.decodeIfPresent(FilenamePattern.self, forKey: .pattern) ?? .timestamp
            autoSaveCaptures = try values.decodeIfPresent(Bool.self, forKey: .autoSaveCaptures) ?? true
        }
    }

    struct ExportSettings: Codable, Equatable {
        var defaultFormat = ExportFormat.png
        var jpegQuality: Double = 0.95
        var includeBackground = true
        var autoCopyToClipboard = true
    }

    struct UpdateSettings: Codable, Equatable {
        var checkOnStartup = true
        var skippedVersion: String?
    }

    struct CloudSettings: Codable, Equatable {
        var r2 = R2Settings()
        var googleDrive = GoogleDriveSettings()
        var docVault = DocVaultSettings()

        private enum CodingKeys: String, CodingKey {
            case r2, googleDrive, docVault
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            r2 = try values.decodeIfPresent(R2Settings.self, forKey: .r2) ?? R2Settings()
            googleDrive = try values.decodeIfPresent(GoogleDriveSettings.self, forKey: .googleDrive) ?? GoogleDriveSettings()
            docVault = try values.decodeIfPresent(DocVaultSettings.self, forKey: .docVault) ?? DocVaultSettings()
        }
    }

    /// The Capture Line: recent captures hang on a line tucked under the menu bar.
    struct CaptureLineSettings: Codable, Equatable {
        var isEnabled = true
        var opensEditorAfterCapture = true
        var hangsSystemScreenshots = true
        var routesSystemScreenshots = false
        var revealsFromMenuBar = true
        var playsSounds = true

        private enum CodingKeys: String, CodingKey {
            case isEnabled, opensEditorAfterCapture, hangsSystemScreenshots
            case routesSystemScreenshots, revealsFromMenuBar, playsSounds
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            opensEditorAfterCapture = try values.decodeIfPresent(Bool.self, forKey: .opensEditorAfterCapture) ?? true
            hangsSystemScreenshots = try values.decodeIfPresent(Bool.self, forKey: .hangsSystemScreenshots) ?? true
            routesSystemScreenshots = try values.decodeIfPresent(Bool.self, forKey: .routesSystemScreenshots) ?? false
            revealsFromMenuBar = try values.decodeIfPresent(Bool.self, forKey: .revealsFromMenuBar) ?? true
            playsSounds = try values.decodeIfPresent(Bool.self, forKey: .playsSounds) ?? true
        }
    }

    struct R2Settings: Codable, Equatable {
        var accountID = ""
        var bucket = ""
        var publicURL = ""
        var directory = ""
    }

    struct GoogleDriveSettings: Codable, Equatable {
        var folderID = ""
    }

    struct DocVaultSettings: Codable, Equatable {
        var serverURL = "https://docvault-backend-xokq.onrender.com"
        var webURL = "https://docvault-dev.vercel.app"
        var workspaceID = ""
    }
}
