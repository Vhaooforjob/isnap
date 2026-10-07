import CoreGraphics
import Foundation
import Vision

struct ScreenshotParseResult: Equatable, Sendable {
    let text: String
    let lineCount: Int
}

actor ScreenshotParserService {
    func parse(_ image: CGImage) throws -> ScreenshotParseResult {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.005
        let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
        // Vision currently identifies Vietnamese as vi-VT; keep vi-VN as a
        // forward-compatible fallback if Apple normalizes the locale later.
        let preferredLanguages = ["vi-VT", "vi-VN", "en-US"].filter(supportedLanguages.contains)
        if !preferredLanguages.isEmpty {
            request.recognitionLanguages = preferredLanguages
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        try Task.checkCancellation()

        let observations = (request.results ?? []).sorted { lhs, rhs in
            let verticalDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            let sameLineTolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.5
            if verticalDistance > sameLineTolerance {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let lines = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        return ScreenshotParseResult(text: lines.joined(separator: "\n"), lineCount: lines.count)
    }
}
