import CryptoKit
import Foundation

struct DuplicateFileGroup: Identifiable {
    let digest: String
    let items: [LibraryItem]
    var id: String { digest }
}
struct DuplicateScanResult {
    let groups: [DuplicateFileGroup]
    let skipped: [String]
    let hashedFiles: Int
}

actor DuplicateFileService {
    /// Compare file bytes, not decoded pixels. Equal-looking files with different encoding are not duplicates here.
    func scan(_ items: [LibraryItem], progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> DuplicateScanResult {
        var seen: Set<URL> = [], sizes: [UInt64: [(LibraryItem, FileRevision)]] = [:], skipped: [String] = []
        for item in items {
            try Task.checkCancellation()
            guard seen.insert(item.url.standardizedFileURL).inserted else { continue }
            do { let revision = try FileRevision.read(item.url); sizes[revision.size, default: []].append((item, revision)) }
            catch { skipped.append(item.name) }
        }
        let candidates = sizes.values.filter { $0.count > 1 }.flatMap { $0 }.sorted { $0.0.url.path < $1.0.url.path }
        var digests: [String: [(LibraryItem, FileRevision)]] = [:]
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let digest = try Self.digest(candidate.0.url)
                guard try FileRevision.read(candidate.0.url) == candidate.1 else { throw CocoaError(.fileReadUnknown) }
                digests[digest, default: []].append(candidate)
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append(candidate.0.name) }
            progress?(index + 1, candidates.count)
        }
        var groups: [DuplicateFileGroup] = []
        for (digest, values) in digests where values.count > 1 {
            try Task.checkCancellation()
            let stable = values.filter { value in
                if (try? FileRevision.read(value.0.url)) == value.1 { return true }
                skipped.append(value.0.name); return false
            }
            guard let first = stable.first else { continue }
            var verified = [first.0]
            for value in stable.dropFirst() {
                do {
                    guard try Self.sameBytes(first.0.url, value.0.url),
                          try FileRevision.read(value.0.url) == value.1 else { throw CocoaError(.fileReadUnknown) }
                    verified.append(value.0)
                } catch is CancellationError { throw CancellationError() }
                catch { skipped.append(value.0.name) }
            }
            guard (try? FileRevision.read(first.0.url)) == first.1 else { skipped.append(first.0.name); continue }
            if verified.count > 1 { groups.append(DuplicateFileGroup(digest: digest, items: verified)) }
        }
        groups.sort { ($0.items.first?.url.path ?? "") < ($1.items.first?.url.path ?? "") }
        return DuplicateScanResult(groups: groups, skipped: Array(Set(skipped)).sorted(), hashedFiles: candidates.count)
    }

    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: a); defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b); defer { try? right.close() }
        while true {
            try Task.checkCancellation()
            let l = try left.read(upToCount: 1_048_576) ?? Data(), r = try right.read(upToCount: 1_048_576) ?? Data()
            if l != r { return false }; if l.isEmpty { return true }
        }
    }
}
