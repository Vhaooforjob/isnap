import AppKit

struct GuideStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var filename: String
    var caption: String
}
struct GuideDraft: Codable, Equatable {
    var title = "Guide"
    var steps: [GuideStep] = []
}
actor GuideService {
    let directory: URL
    init(directory: URL = StorageService.appSupport.appendingPathComponent("GuideDraft", isDirectory: true)) { self.directory = directory }
    func load() throws -> GuideDraft {
        let url = directory.appendingPathComponent("guide.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return GuideDraft() }
        let draft = try JSONDecoder().decode(GuideDraft.self, from: Data(contentsOf: url))
        guard draft.steps.count <= 500, draft.steps.allSatisfy({ $0.filename == URL(fileURLWithPath: $0.filename).lastPathComponent && !$0.filename.hasPrefix(".") }) else { throw ExportError.invalidImage }
        return draft
    }
    func save(_ draft: GuideDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("guide.json"), options: .atomic)
    }
    func append(_ image: CGImage, draft: GuideDraft) throws -> GuideDraft {
        guard draft.steps.count < 500 else { throw StitchError.tooLarge }
        let filename = UUID().uuidString + ".png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ExportError.encodingFailed }
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .withoutOverwriting)
        var result = draft; result.steps.append(GuideStep(filename: filename, caption: ""))
        do { try save(result) } catch { try? FileManager.default.removeItem(at: url); throw error }
        return result
    }
    func imageURL(_ step: GuideStep) -> URL { directory.appendingPathComponent(step.filename) }
    func export(_ draft: GuideDraft, to target: URL, pdf: Bool) async throws {
        guard !draft.steps.isEmpty, draft.steps.count <= 500 else { throw ExportError.invalidImage }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".isnap-guide-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var pages: [CompositionPage] = [], markdown = "# \(Self.escape(draft.title))\n\n"
        for (index, step) in draft.steps.enumerated() {
            try Task.checkCancellation()
            let image = try ImageIOService.fullImage(at: directory.appendingPathComponent(step.filename))
            // A separate header carries the number without covering screenshot content or revealing redactions.
            let numbered = try Self.numbered(image, number: index + 1)
            guard let data = NSBitmapImageRep(cgImage: numbered).representation(using: .png, properties: [:]) else { throw ExportError.encodingFailed }
            let name = String(format: "step-%03d.png", index + 1), url = stage.appendingPathComponent(name)
            try data.write(to: url, options: .withoutOverwriting)
            pages.append(CompositionPage(url: url, caption: "\(index + 1). \(step.caption)"))
            markdown += "## \(index + 1). \(Self.escape(step.caption))\n\n![Step \(index + 1)](\(name))\n\n"
        }
        if pdf {
            let data = try await CompositionService().pdf(pages, captions: true, searchable: false, layout: .a4)
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
        } else {
            try Data(markdown.utf8).write(to: stage.appendingPathComponent("README.md"), options: .atomic)
            try Task.checkCancellation()
            // Move into an unused destination atomically; never replace an existing guide folder.
            try FileManager.default.moveItem(at: stage, to: target)
        }
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .reduce("") { $0 + ("\\`*_{}[]<>#!|".contains($1) ? "\\" : "") + String($1) }
    }
    static func numbered(_ image: CGImage, number: Int) throws -> CGImage {
        let h = image.height + 64
        guard image.width * h <= 80_000_000,
              let ctx = CGContext(data: nil, width: image.width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.tooLarge }
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSString(string: "\(number)").draw(at: CGPoint(x: 20, y: image.height + 15), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let result = ctx.makeImage() else { throw ExportError.invalidImage }; return result
    }
}
