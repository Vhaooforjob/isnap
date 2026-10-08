import CryptoKit
import Foundation

enum CloudUploadError: LocalizedError {
    case notConfigured(String)
    case invalidResponse(String)
    case fileTooLarge
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider): String(localized: "\(provider) is not configured.")
        case .invalidResponse(let message): message
        case .fileTooLarge: String(localized: "The rendered image exceeds the 50 MB upload limit.")
        case .authorizationFailed(let message): String(localized: "Authorization failed: \(message)")
        }
    }
}

actor R2Uploader {
    private let keychain: KeychainStore
    private let session: URLSession

    init(keychain: KeychainStore = .shared, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    func isConfigured(_ config: AppSettings.R2Settings) -> Bool {
        !config.accountID.isEmpty && !config.bucket.isEmpty && !config.publicURL.isEmpty &&
        keychain.value(for: .r2AccessKeyID) != nil && keychain.value(for: .r2SecretAccessKey) != nil
    }

    func saveCredentials(accessKeyID: String, secretAccessKey: String) throws {
        try keychain.set(accessKeyID, for: .r2AccessKeyID)
        try keychain.set(secretAccessKey, for: .r2SecretAccessKey)
    }

    func test(_ config: AppSettings.R2Settings) async throws {
        _ = try await request(config: config, method: "HEAD", objectKey: nil, body: Data(), contentType: "application/octet-stream")
    }

    func upload(_ data: Data, filename: String, config: AppSettings.R2Settings) async throws -> URL {
        guard data.count <= 50 * 1024 * 1024 else { throw CloudUploadError.fileTooLarge }
        let directory = config.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = directory.isEmpty ? filename : "\(directory)/\(filename)"
        _ = try await request(
            config: config,
            method: "PUT",
            objectKey: key,
            body: data,
            contentType: filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
        )
        let encodedPath = key.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        guard let url = URL(string: config.publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + encodedPath) else {
            throw CloudUploadError.invalidResponse("The configured R2 public URL is invalid.")
        }
        return url
    }

    private func request(
        config: AppSettings.R2Settings,
        method: String,
        objectKey: String?,
        body: Data,
        contentType: String
    ) async throws -> HTTPURLResponse {
        guard isConfigured(config),
              let accessKey = keychain.value(for: .r2AccessKeyID),
              let secretKey = keychain.value(for: .r2SecretAccessKey) else {
            throw CloudUploadError.notConfigured("Cloudflare R2")
        }
        let host = "\(config.accountID).r2.cloudflarestorage.com"
        let pathParts = ([config.bucket] + (objectKey?.split(separator: "/").map(String.init) ?? []))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .r2PathComponent) ?? $0 }
        let canonicalURI = "/" + pathParts.joined(separator: "/")
        guard let url = URL(string: "https://\(host)\(canonicalURI)") else {
            throw CloudUploadError.invalidResponse("The R2 endpoint is invalid.")
        }
        let now = Date()
        let dateTime = Self.amzDate.string(from: now)
        let date = Self.shortDate.string(from: now)
        let payloadHash = body.sha256Hex
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(dateTime)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [method, canonicalURI, "", canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(date)/auto/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(dateTime)\n\(scope)\n\(Data(canonicalRequest.utf8).sha256Hex)"
        let dateKey = HMAC<SHA256>.authenticationCode(for: Data(date.utf8), using: SymmetricKey(data: Data("AWS4\(secretKey)".utf8)))
        let regionKey = HMAC<SHA256>.authenticationCode(for: Data("auto".utf8), using: SymmetricKey(data: Data(dateKey)))
        let serviceKey = HMAC<SHA256>.authenticationCode(for: Data("s3".utf8), using: SymmetricKey(data: Data(regionKey)))
        let signingKey = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: Data(serviceKey)))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: Data(signingKey)))).hex

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = method == "HEAD" ? 10 : 60
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(dateTime, forHTTPHeaderField: "x-amz-date")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudUploadError.invalidResponse("R2 returned HTTP \(status). Check the bucket, token permissions, and account ID.")
        }
        return http
    }

    private static let amzDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

private extension CharacterSet {
    static let r2PathComponent = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
}

private extension Data {
    var sha256Hex: String { Data(SHA256.hash(data: self)).hex }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

