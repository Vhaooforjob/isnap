import Foundation

struct RedactionRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pattern: String
    var regularExpression = false
    var enabled = true

    func expression() throws -> NSRegularExpression {
        guard pattern.utf16.count <= 1024 else { throw RedactionMatchError.budgetExceeded }
        return try NSRegularExpression(pattern: regularExpression ? pattern : NSRegularExpression.escapedPattern(for: pattern),
            options: [.caseInsensitive])
    }

    static func suggestions(in regions: [RecognizedRegion], rules: [RedactionRule]) async throws -> [RecognizedRegion] {
        try await RedactionMatcher().match(regions, rules: rules, wholeLines: true).map(\.region)
    }

}

struct RedactionMatch: Identifiable, Sendable {
    let region: RecognizedRegion
    let reason: String
    var id: UUID { region.id }
}

enum RedactionMatchError: LocalizedError {
    case budgetExceeded
    var errorDescription: String? {
        String(localized: "Matching stopped because a rule took too long or the input was too large. Simplify the rule or scan a smaller image. No partial suggestions were applied.")
    }
}

actor RedactionMatcher {
    func match(_ regions: [RecognizedRegion], rules: [RedactionRule], wholeLines: Bool) throws -> [RedactionMatch] {
        guard regions.count <= 20_000, rules.count <= 100 else { throw RedactionMatchError.budgetExceeded }
        var expressions: [(String, NSRegularExpression)] = [
            (String(localized: "Email address"), try NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive)),
            (String(localized: "Phone number"), try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue))
        ]
        for rule in rules where rule.enabled && !rule.pattern.isEmpty {
            guard rule.pattern.utf16.count <= 1024 else { throw RedactionMatchError.budgetExceeded }
            expressions.append((rule.name, try rule.expression()))
        }
        let deadline = Date().addingTimeInterval(3)
        var results: [RedactionMatch] = []
        for line in regions {
            try Task.checkCancellation()
            guard line.text.utf16.count <= 8192 else { throw RedactionMatchError.budgetExceeded }
            var ranges: [(NSRange, String)] = []
            for (name, expression) in expressions {
                var stopped = false
                let sliceDeadline = min(deadline, Date().addingTimeInterval(0.15))
                expression.enumerateMatches(in: line.text, options: [.reportProgress], range: NSRange(line.text.startIndex..., in: line.text)) { match, _, stop in
                    if Task.isCancelled || Date() > sliceDeadline { stop.pointee = true; stopped = true; return }
                    if let match, match.range.length > 0 { ranges.append((match.range, name)) }
                }
                try Task.checkCancellation()
                if stopped || Date() > deadline { throw RedactionMatchError.budgetExceeded }
            }
            if wholeLines, !ranges.isEmpty {
                results.append(RedactionMatch(region: line, reason: Array(Set(ranges.map { $0.1 })).sorted().joined(separator: ", ")))
            } else {
                for (range, reason) in ranges {
                    guard let stringRange = Range(range, in: line.text) else { continue }
                    let rect = line.boundingRect(for: range)
                    if let index = results.firstIndex(where: { $0.region.rect == rect && $0.region.text == String(line.text[stringRange]) }) {
                        let old = results[index]
                        results[index] = RedactionMatch(region: old.region, reason: old.reason + ", " + reason)
                    } else {
                        results.append(RedactionMatch(region: RecognizedRegion(text: String(line.text[stringRange]), rect: rect), reason: reason))
                    }
                }
            }
        }
        return results
    }
}
