import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

struct ReleaseInfo: Decodable, Identifiable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL

    var id: String { tagName }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
    }
}

actor UpdateService {
    private let releasesURL = URL(string: "https://api.github.com/repos/Vhaooforjob/isnap/releases/latest")!

    func latestRelease(currentVersion: String) async throws -> ReleaseInfo? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending ? release : nil
    }
}


/// The distribution pipeline embeds the public key only after a signed feed is configured.
@MainActor
final class AppUpdater {
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    static func configured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String, let bytes = Data(base64Encoded: key), bytes.count == 32 else { return false }
        return true
    }
    func check(interactive: Bool) -> Bool {
        #if canImport(Sparkle)
        guard Self.configured(Bundle.main.infoDictionary ?? [:]) else { return false }
        if controller == nil { controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) }
        if interactive, controller?.updater.canCheckForUpdates == true { controller?.checkForUpdates(nil) }
        return true
        #else
        return false
        #endif
    }
}
