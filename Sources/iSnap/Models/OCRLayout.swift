import Foundation

enum OCRLayout {
    static func rows(_ regions: [RecognizedRegion]) -> [[RecognizedRegion]] {
        var rows: [[RecognizedRegion]] = []
        for region in regions.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let index = rows.indices.last(where: {
                guard let anchor = rows[$0].first else { return false }
                return abs(anchor.rect.midY - region.rect.midY) < max(anchor.rect.height, region.rect.height) * 0.55
            }) { rows[index].append(region) }
            else { rows.append([region]) }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    static func plain(_ regions: [RecognizedRegion], preserveLayout: Bool) -> String {
        rows(regions).map { row in
            guard preserveLayout else { return row.map(\.text).joined(separator: " ") }
            let widths = row.map { $0.rect.width / CGFloat(max(1, $0.text.count)) }.sorted()
            let unit = max(1, widths[widths.count / 2])
            var line = "", end: CGFloat = row.first?.rect.minX ?? 0
            for cell in row {
                let spaces = min(200, max(line.isEmpty ? 0 : 1, Int(((cell.rect.minX - end) / unit).rounded())))
                line += String(repeating: " ", count: spaces) + cell.text; end = cell.rect.maxX
            }
            return line
        }.joined(separator: "\n")
    }

    static func csv(_ regions: [RecognizedRegion]) -> String {
        let rows = rows(regions)
        var columns: [CGFloat] = []
        let tolerance = max(8, regions.map { $0.rect.height }.sorted().dropFirst(regions.count / 2).first ?? 12)
        for cell in regions.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if !columns.contains(where: { abs($0 - cell.rect.minX) < tolerance }) { columns.append(cell.rect.minX) }
        }
        return rows.map { row in
            var values = [String](repeating: "", count: columns.count)
            for cell in row {
                guard let index = columns.indices.min(by: { abs(columns[$0] - cell.rect.minX) < abs(columns[$1] - cell.rect.minX) }) else { continue }
                values[index] += (values[index].isEmpty ? "" : " ") + cell.text
            }
            return values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
        }.joined(separator: "\r\n")
    }
}
