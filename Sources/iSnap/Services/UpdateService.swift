import Foundation

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

