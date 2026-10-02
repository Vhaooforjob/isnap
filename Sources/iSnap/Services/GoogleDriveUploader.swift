import AppKit
import Foundation
import Network

private struct GoogleOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt, tokenType = "token_type"
    }
}

actor GoogleDriveUploader {
    private let keychain: KeychainStore
    private let session: URLSession
    private var listener: NWListener?

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func hasCredentials() -> Bool {
        keychain.value(for: .googleClientID) != nil && keychain.value(for: .googleClientSecret) != nil
    }

    func isConnected() -> Bool { keychain.value(for: .googleOAuthToken) != nil }

    func saveCredentials(clientID: String, clientSecret: String) throws {
        try keychain.set(clientID, for: .googleClientID)
        try keychain.set(clientSecret, for: .googleClientSecret)
    }

    func authorize() async throws {
        guard let clientID = keychain.value(for: .googleClientID), keychain.value(for: .googleClientSecret) != nil else {
            throw CloudUploadError.notConfigured("Google Drive OAuth")
        }
        let state = UUID().uuidString
        let redirect = "http://127.0.0.1:8089/callback"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = components.url else { throw CloudUploadError.authorizationFailed("Invalid OAuth URL") }
        let code = try await waitForAuthorizationCode(expectedState: state, opening: authURL)
        try await exchangeCode(code, redirectURI: redirect)
    }

    func disconnect() throws { try keychain.remove(.googleOAuthToken) }

    func upload(_ data: Data, filename: String, folderID: String) async throws -> URL {
        guard data.count <= 50 * 1024 * 1024 else { throw CloudUploadError.fileTooLarge }
        let token = try await validToken()
        let boundary = "iSnap-\(UUID().uuidString)"
        var metadata: [String: Any] = [
            "name": filename,
            "mimeType": filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
        ]
        if !folderID.isEmpty { metadata["parents"] = [folderID] }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataData)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(metadata["mimeType"]!)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let fileID = json["id"] as? String else {
            throw CloudUploadError.invalidResponse("Google Drive upload failed.")
        }
        try await makePublic(fileID: fileID, token: token.accessToken)
        return URL(string: "https://drive.google.com/file/d/\(fileID)/view")!
    }

    private func waitForAuthorizationCode(expectedState: String, opening url: URL) async throws -> String {
        let listener = try NWListener(using: .tcp, on: 8089)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                listener.cancel()
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                    defer {
                        let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<h2>iSnap connected to Google Drive.</h2><p>You may close this window.</p>"
                        connection.send(content: Data(html.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                    if let error { finish(.failure(error)); return }
                    guard let data, let request = String(data: data, encoding: .utf8),
                          let firstLine = request.components(separatedBy: "\r\n").first,
                          let target = firstLine.split(separator: " ").dropFirst().first,
                          let components = URLComponents(string: "http://127.0.0.1\(target)") else {
                        finish(.failure(CloudUploadError.authorizationFailed("Invalid callback"))); return
                    }
                    let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                    guard values["state"] == expectedState else {
                        finish(.failure(CloudUploadError.authorizationFailed("State mismatch"))); return
                    }
                    if let code = values["code"], !code.isEmpty { finish(.success(code)) }
                    else { finish(.failure(CloudUploadError.authorizationFailed(values["error"] ?? "No code received"))) }
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { finish(.failure(error)) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    private func exchangeCode(_ code: String, redirectURI: String) async throws {
        guard let clientID = keychain.value(for: .googleClientID),
              let secret = keychain.value(for: .googleClientSecret) else { throw CloudUploadError.notConfigured("Google OAuth") }
        let form = [
            "code": code,
            "client_id": clientID,
            "client_secret": secret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        let json = try await tokenRequest(form)
        try storeToken(json, preservingRefreshToken: nil)
    }

    private func validToken() async throws -> GoogleOAuthToken {
        guard let raw = keychain.value(for: .googleOAuthToken), let data = raw.data(using: .utf8),
              var token = try? JSONDecoder().decode(GoogleOAuthToken.self, from: data) else {
            throw CloudUploadError.notConfigured("Google Drive")
        }
        if token.expiresAt > Date().addingTimeInterval(60) { return token }
        guard let refresh = token.refreshToken,
              let clientID = keychain.value(for: .googleClientID),
              let secret = keychain.value(for: .googleClientSecret) else {
            throw CloudUploadError.authorizationFailed("Reconnect Google Drive")
        }
        let json = try await tokenRequest([
            "refresh_token": refresh,
            "client_id": clientID,
            "client_secret": secret,
            "grant_type": "refresh_token"
        ])
        try storeToken(json, preservingRefreshToken: refresh)
        guard let stored = keychain.value(for: .googleOAuthToken)?.data(using: .utf8) else { return token }
        token = try JSONDecoder().decode(GoogleOAuthToken.self, from: stored)
        return token
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { key, value in
            "\(key.urlEncoded)=\(value.urlEncoded)"
        }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudUploadError.authorizationFailed("Token exchange was rejected")
        }
        return json
    }

    private func storeToken(_ json: [String: Any], preservingRefreshToken: String?) throws {
        guard let access = json["access_token"] as? String else { throw CloudUploadError.authorizationFailed("Missing access token") }
        let expires = json["expires_in"] as? Double ?? 3600
        let token = GoogleOAuthToken(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? preservingRefreshToken,
            expiresAt: Date().addingTimeInterval(expires),
            tokenType: json["token_type"] as? String ?? "Bearer"
        )
        let data = try JSONEncoder().encode(token)
        try keychain.set(String(decoding: data, as: UTF8.self), for: .googleOAuthToken)
    }

    private func makePublic(fileID: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "anyone", "role": "reader"])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudUploadError.invalidResponse("Uploaded to Google Drive, but public sharing failed.")
        }
    }
}

private extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self }
}

private extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

