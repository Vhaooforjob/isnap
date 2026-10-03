import Foundation

struct AppSettings: Codable, Equatable {
    var hotkeys = HotkeySettings()
    var startup = StartupSettings()
    var quickSave = QuickSaveSettings()
    var export = ExportSettings()
    var canvas = CanvasConfiguration()
    var update = UpdateSettings()
    var cloud = CloudSettings()
    var backgroundImages: [URL] = []

    struct HotkeySettings: Codable, Equatable {
        var fullScreen = "⌃⌥1"
        var region = "⌃⌥2"
        var window = "⌃⌥3"
        var saveEditedImage = "⌘S"
        var copyEditedImage = "⌘C"

        private enum CodingKeys: String, CodingKey {
            case fullScreen, region, window, saveEditedImage, copyEditedImage
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fullScreen = try values.decodeIfPresent(String.self, forKey: .fullScreen) ?? "⌃⌥1"
            region = try values.decodeIfPresent(String.self, forKey: .region) ?? "⌃⌥2"
            window = try values.decodeIfPresent(String.self, forKey: .window) ?? "⌃⌥3"
            saveEditedImage = try values.decodeIfPresent(String.self, forKey: .saveEditedImage) ?? "⌘S"
            copyEditedImage = try values.decodeIfPresent(String.self, forKey: .copyEditedImage) ?? "⌘C"
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
}
