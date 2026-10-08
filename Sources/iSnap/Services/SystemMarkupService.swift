import AppKit
import UniformTypeIdentifiers

/// Opens an image in the system Markup editor, the window macOS shows when
/// you click a fresh screenshot thumbnail, and writes the result back over
/// the file. Adapted from Tendedero (MIT).
@MainActor
final class SystemMarkupService: NSObject, NSSharingServiceDelegate {
    static let shared = SystemMarkupService()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    private var editing: URL?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL) {
        guard let service = NSSharingService(named: Self.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            return
        }
        editing = url
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { save(items) }
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        guard let target = editing, let item = items.first else { return }
        editing = nil
        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: Self.pngData(image), to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            break
        }
    }

    private func load(_ provider: NSItemProvider, into target: URL) {
        let types = provider.registeredTypeIdentifiers
        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if let url { self.write(from: url, to: target) } }
                }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        guard let imageType = types.first(where: { $0 == original })
                ?? types.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.write(data: data, to: target) }
            }
        }
    }

    private func write(from source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            onSaved(target)
        } else {
            write(data: try? Data(contentsOf: source), to: target)
        }
    }

    private func write(data: Data?, to target: URL) {
        guard let data else { return }
        do {
            try data.write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            NSSound.beep()
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
