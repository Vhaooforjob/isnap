import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

struct DocVaultUser: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String
}

struct DocVaultWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct DocVaultStorageAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let label: String
    let status: String
    let isDefaultStorage: Bool
    let quotaBytes: Int64?
    let quotaUsedBytes: Int64?
    let quotaCheckedAt: String?

    var remainingBytes: Int64? {
        guard let quotaBytes, let quotaUsedBytes else { return nil }
        return max(0, quotaBytes - quotaUsedBytes)
    }
}

struct DocVaultSnapshot: Sendable {
    let user: DocVaultUser
    let workspaces: [DocVaultWorkspace]
    let storageAccounts: [DocVaultStorageAccount]
}

private struct DocVaultSession: Codable {
    var accessToken: String
    var refreshToken: String
    var user: DocVaultUser
    var serverOrigin: String
}

private struct DocVaultAuthPayload: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: DocVaultUser
}

private struct DocVaultTokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String
}

private struct DocVaultFile: Decodable {
    let id: String
}

private struct DocVaultEnvelope<Value: Decodable>: Decodable {
    let data: Value?
    let error: DocVaultAPIError?
}

private struct DocVaultAPIError: Decodable {
    let code: String?
    let message: String?
}

enum DocVaultError: LocalizedError {
    case invalidServerURL
    case notConnected
    case loginCancelled
    case authorizationFailed(String)
    case api(String)
    case invalidResponse
    case workspaceRequired

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: String(localized: "Enter a valid HTTPS DocVault server URL. HTTP is allowed for localhost.")
        case .notConnected: String(localized: "Connect iSnap to DocVault first.")
        case .loginCancelled: String(localized: "DocVault sign-in was cancelled.")
        case .authorizationFailed(let message): String(localized: "DocVault sign-in failed: \(message)")
        case .api(let message): message
        case .invalidResponse: String(localized: "DocVault returned an invalid response.")
        case .workspaceRequired: String(localized: "Choose a DocVault workspace before uploading.")
        }
    }
}

actor DocVaultService {
    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func isConnected(config: AppSettings.DocVaultSettings) -> Bool {
        guard let stored = storedSession(), let origin = try? serverOrigin(config.serverURL) else { return false }
        return stored.serverOrigin == origin
    }

    func connect(config: AppSettings.DocVaultSettings) async throws -> DocVaultSnapshot {
        let origin = try serverOrigin(config.serverURL)
        let verifier = Self.makeVerifier()
        let challenge = Self.challenge(for: verifier)
        var components = URLComponents(url: try apiURL(config.serverURL, path: "auth/google/login"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client", value: "isnap"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        guard let authorizationURL = components?.url else { throw DocVaultError.invalidServerURL }
        let callback = try await DocVaultOAuthCoordinator.shared.authenticate(url: authorizationURL)
        guard callback.scheme == "isnap", callback.host == "docvault" else {
            throw DocVaultError.authorizationFailed("Unexpected callback URL")
        }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let message = values.first(where: { $0.name == "error" })?.value {
            throw DocVaultError.authorizationFailed(message)
        }
        guard let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw DocVaultError.authorizationFailed("The server did not return a login code")
        }

        var request = URLRequest(url: try apiURL(config.serverURL, path: "auth/google"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "codeVerifier": verifier])
        let (data, response) = try await session.data(for: request)
        let payload: DocVaultAuthPayload = try decode(data, response: response)
        try store(DocVaultSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            user: payload.user,
            serverOrigin: origin
        ))
        return try await snapshot(config: config)
    }

    func disconnect(config: AppSettings.DocVaultSettings) async throws {
        let stored = storedSession()
        defer { try? keychain.remove(.docVaultSession) }
        guard let stored, stored.serverOrigin == (try? serverOrigin(config.serverURL)) else { return }
        var request = URLRequest(url: try apiURL(config.serverURL, path: "auth/logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": stored.refreshToken])
        _ = try? await session.data(for: request)
    }

    func snapshot(config: AppSettings.DocVaultSettings) async throws -> DocVaultSnapshot {
        let user: DocVaultUser = try await get(config: config, path: "auth/me")
        let workspaces: [DocVaultWorkspace] = try await get(config: config, path: "workspaces?limit=100")
        let accounts: [DocVaultStorageAccount] = try await get(config: config, path: "auth/google/storage-accounts")
        return DocVaultSnapshot(user: user, workspaces: workspaces, storageAccounts: accounts)
    }

    func setDefaultStorageAccount(
        _ accountID: String,
        config: AppSettings.DocVaultSettings
    ) async throws -> DocVaultStorageAccount {
        var request = URLRequest(url: try apiURL(config.serverURL, path: "auth/google/storage-accounts/\(accountID)/default"))
        request.httpMethod = "PATCH"
        return try await authorized(request, config: config)
    }

    func upload(
        _ data: Data,
        filename: String,
        config: AppSettings.DocVaultSettings
    ) async throws -> URL {
        guard !config.workspaceID.isEmpty else { throw DocVaultError.workspaceRequired }
        guard var web = URL(string: config.webURL), ["http", "https"].contains(web.scheme?.lowercased() ?? "") else {
            throw DocVaultError.api("Enter a valid DocVault web URL.")
        }
        let boundary = "iSnap-DocVault-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isnap-docvault-\(UUID().uuidString).upload")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: bodyURL) else {
            throw DocVaultError.api("Could not prepare the DocVault upload.")
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        do {
            try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"workspaceId\"\r\n\r\n\(config.workspaceID)\r\n".utf8))
            try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nUploaded from iSnap\r\n".utf8))
            let mime = filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
            try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.safeFilename(filename))\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let file: DocVaultFile = try await uploadBody(
            bodyURL,
            boundary: boundary,
            config: config,
            idempotencyKey: UUID().uuidString
        )
        web.append(path: "preview")
        web.append(path: file.id)
        return web
    }

    private func uploadBody<Value: Decodable>(
        _ bodyURL: URL,
        boundary: String,
        config: AppSettings.DocVaultSettings,
        idempotencyKey: String,
        retrying: Bool = false
    ) async throws -> Value {
        let stored = try matchingSession(config)
        var request = URLRequest(url: try apiURL(config.serverURL, path: "files"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        if (response as? HTTPURLResponse)?.statusCode == 401, !retrying {
            try await refresh(config: config)
            return try await uploadBody(
                bodyURL,
                boundary: boundary,
                config: config,
                idempotencyKey: idempotencyKey,
                retrying: true
            )
        }
        return try decode(data, response: response)
    }

    private func get<Value: Decodable>(config: AppSettings.DocVaultSettings, path: String) async throws -> Value {
        try await authorized(URLRequest(url: try apiURL(config.serverURL, path: path)), config: config)
    }

    private func authorized<Value: Decodable>(
        _ original: URLRequest,
        config: AppSettings.DocVaultSettings,
        retrying: Bool = false
    ) async throws -> Value {
        let stored = try matchingSession(config)
        var request = original
        request.timeoutInterval = 30
        request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, !retrying {
            try await refresh(config: config)
            return try await authorized(original, config: config, retrying: true)
        }
        return try decode(data, response: response)
    }

    private func refresh(config: AppSettings.DocVaultSettings) async throws {
        var stored = try matchingSession(config)
        var request = URLRequest(url: try apiURL(config.serverURL, path: "auth/refresh"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": stored.refreshToken])
        let (data, response) = try await session.data(for: request)
        let payload: DocVaultTokenPayload = try decode(data, response: response)
        stored.accessToken = payload.accessToken
        stored.refreshToken = payload.refreshToken
        try store(stored)
    }

    private func decode<Value: Decodable>(_ data: Data, response: URLResponse) throws -> Value {
        guard let http = response as? HTTPURLResponse else { throw DocVaultError.invalidResponse }
        let envelope = try? JSONDecoder().decode(DocVaultEnvelope<Value>.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = envelope?.error?.message ?? "DocVault returned HTTP \(http.statusCode)."
            throw DocVaultError.api(message)
        }
        guard let value = envelope?.data else { throw DocVaultError.invalidResponse }
        return value
    }

    private func matchingSession(_ config: AppSettings.DocVaultSettings) throws -> DocVaultSession {
        guard let stored = storedSession(), stored.serverOrigin == (try? serverOrigin(config.serverURL)) else {
            throw DocVaultError.notConnected
        }
        return stored
    }

    private func storedSession() -> DocVaultSession? {
        guard let raw = keychain.value(for: .docVaultSession), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocVaultSession.self, from: data)
    }

    private func store(_ value: DocVaultSession) throws {
        let data = try JSONEncoder().encode(value)
        try keychain.set(String(decoding: data, as: UTF8.self), for: .docVaultSession)
    }

    private func serverOrigin(_ raw: String) throws -> String {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw DocVaultError.invalidServerURL
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.lowercased()
        components.port = url.port
        guard let origin = components.string else { throw DocVaultError.invalidServerURL }
        return origin
    }

    private func apiURL(_ raw: String, path: String) throws -> URL {
        let origin = try serverOrigin(raw)
        var basePath = URL(string: raw)?.path ?? ""
        basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.hasSuffix("api/v1") { basePath = String(basePath.dropLast(6)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var url = URL(string: origin)!
        if !basePath.isEmpty { url.append(path: basePath) }
        url.append(path: "api")
        url.append(path: "v1")
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        for component in pieces[0].split(separator: "/") { url.append(path: String(component)) }
        if pieces.count == 2, var values = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            values.percentEncodedQuery = pieces[1]
            if let result = values.url { return result }
        }
        return url
    }

    private static func makeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func safeFilename(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
    }
}

@MainActor
private final class DocVaultOAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DocVaultOAuthCoordinator()
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(url: URL) async throws -> URL {
        if activeSession != nil { throw DocVaultError.authorizationFailed("Another sign-in is already running") }
        return try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "isnap") { [weak self] callback, error in
                self?.activeSession = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: DocVaultError.loginCancelled)
                } else {
                    continuation.resume(throwing: DocVaultError.authorizationFailed(error?.localizedDescription ?? "Unknown error"))
                }
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            activeSession = authSession
            if !authSession.start() {
                activeSession = nil
                continuation.resume(throwing: DocVaultError.authorizationFailed("Could not open the sign-in window"))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
