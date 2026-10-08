import Foundation

/// The interface language. iSnap writes the choice to its own
/// `AppleLanguages` default, the same override macOS uses for per-app
/// languages, so SwiftUI, AppKit menus, and system panels all follow it
/// after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case vietnamese = "vi"

    var id: String { rawValue }

    /// Language names stay in their own language so they can always be found.
    var title: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    private static let overrideKey = "AppleLanguages"

    /// The saved choice, which may differ from the running language until relaunch.
    static func saved(in defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        guard let bundleID,
              let override = defaults.persistentDomain(forName: bundleID)?[overrideKey] as? [String],
              let first = override.first else { return .system }
        if first.hasPrefix("vi") { return .vietnamese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    static func save(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: overrideKey)
        } else {
            defaults.set([language.rawValue], forKey: overrideKey)
        }
    }
}
