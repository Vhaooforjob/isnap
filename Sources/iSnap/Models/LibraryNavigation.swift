import Foundation

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, name, fileSize, dimensions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: String(localized: "Newest First")
        case .oldest: String(localized: "Oldest First")
        case .name: String(localized: "Name")
        case .fileSize: String(localized: "Largest File")
        case .dimensions: String(localized: "Largest Dimensions")
        }
    }

    func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { a, b in
            switch self {
            case .newest where a.modifiedAt != b.modifiedAt: return a.modifiedAt > b.modifiedAt
            case .oldest where a.modifiedAt != b.modifiedAt: return a.modifiedAt < b.modifiedAt
            case .fileSize where a.byteCount != b.byteCount: return a.byteCount > b.byteCount
            case .dimensions where a.dimensions != b.dimensions:
                let left = a.dimensions.width * a.dimensions.height, right = b.dimensions.width * b.dimensions.height
                if left != right { return left > right }
            default: break
            }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.url.path < b.url.path : order == .orderedAscending
        }
    }
}

enum LibraryNavigation {
    static func range(from anchor: URL?, to target: URL, in urls: [URL]) -> Set<URL> {
        guard let anchor, let start = urls.firstIndex(of: anchor), let end = urls.firstIndex(of: target) else { return [target] }
        return Set(urls[min(start, end)...max(start, end)])
    }

    static func snippet(_ text: String, query: String) -> String? {
        guard !query.isEmpty, let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 65, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end == text.endIndex ? "" : "…")
    }
}
