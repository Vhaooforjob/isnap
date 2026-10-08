import AppKit
import Combine
import Foundation

/// One capture hanging on the Capture Line.
struct HangingCapture: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumbnail: NSImage
    /// Every card hangs a little crooked, like a photo on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var isFalling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var isFlying = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.isFalling == rhs.isFalling && lhs.isFlying == rhs.isFlying
            && lhs.thumbnail === rhs.thumbnail
    }
}

/// What hangs on the Capture Line and what can be done with each card.
/// The files never move on their own; the line is only a view onto them.
/// Interaction model adapted from Tendedero (MIT), see THIRD_PARTY_NOTICES.md.
@MainActor
final class CaptureLine: ObservableObject {
    @Published private(set) var items: [HangingCapture] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var isRevealed = false

    /// Card frames in panel coordinates, reported by the views. The panel
    /// only catches clicks over cards and lets the rest through.
    var hitRects: [UUID: CGRect] = [:]
    var maxItems = 8
    var playsSounds = true

    /// Opens a capture in the iSnap editor.
    var onEdit: ((URL) -> Void)?
    /// Builds the Share menu for a capture.
    var shareMenu: ((URL) -> NSMenu)?
    /// Called just before a card starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((HangingCapture) -> Void)?

    /// iSnap's own folder for captures that exist only on the line: new
    /// captures when Library archiving is off, and routed macOS screenshots.
    /// Files here are trashed when taken down; files anywhere else, such as
    /// the Library, stay where they are.
    let ownedFolder: URL

    private let defaults: UserDefaults
    private let storeKey = "captureLine.items"
    private var gustTask: Task<Void, Never>?

    nonisolated static let defaultOwnedFolder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("iSnap/Line", isDirectory: true)

    init(ownedFolder: URL = CaptureLine.defaultOwnedFolder, defaults: UserDefaults = .standard) {
        self.ownedFolder = ownedFolder
        self.defaults = defaults
        restore()
        scheduleGust()
    }

    var liveCount: Int { items.filter { !$0.isFalling }.count }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.isFalling }),
              let thumbnail = Self.thumbnail(url) else { return nil }
        var item = HangingCapture(url: url, thumbnail: thumbnail)
        item.isFlying = flying
        items.append(item)
        // A full line lets the oldest card fall off the far end.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.isFalling }) {
            drop(oldest.id, quietly: true)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture reached the line: the real card takes over from the flight.
    func land(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFlying = false
    }

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFalling else { return }
        onFall?(items[index])
        items[index].isFalling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.isFalling }
        for (offset, item) in live.enumerated() {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60 * offset))
                self?.drop(item.id, quietly: offset > 0)
            }
        }
    }

    /// Cards whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.isFalling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one card

    func copy(_ id: UUID) {
        guard let item = item(id) else { return }
        let entry = NSPasteboardItem()
        if let png = Self.pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])

        copiedID = id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func edit(_ id: UUID) {
        guard let item = item(id) else { return }
        onEdit?(item.url)
    }

    func openExternally(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func markup(_ id: UUID) {
        guard let item = item(id) else { return }
        SystemMarkupService.shared.edit(item.url)
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Moves the file to the Trash and takes the card off the line.
    func trash(_ id: UUID) {
        guard let item = item(id) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if playsSounds { Self.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            NSSound.beep()
        }
    }

    func isOwned(_ id: UUID) -> Bool {
        guard let item = item(id) else { return false }
        return isOwned(item.url)
    }

    func isOwned(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(ownedFolder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take Down" both end here. Captures that only
    /// live on the line go to the Trash, or the folder would fill up with
    /// forgotten screenshots; Library files are left untouched.
    func discard(_ id: UUID) {
        if isOwned(id) { trash(id) } else { drop(id) }
    }

    /// Keeps a line-only capture by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = item(id) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        do {
            try FileManager.default.moveItem(at: item.url, to: Self.uniqueURL(in: desktop, for: item.url.lastPathComponent))
            drop(id, quietly: true)
        } catch {
            NSSound.beep()
        }
    }

    /// After editing, the card shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let index = items.firstIndex(where: { $0.url == url && !$0.isFalling }),
              let thumbnail = Self.thumbnail(url) else { return }
        items[index].thumbnail = thumbnail
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line.
    private func scheduleGust() {
        gustTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 7...16)))
                guard let self else { return }
                if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            }
        }
    }

    // MARK: Persistence

    private func save() {
        defaults.set(items.filter { !$0.isFalling }.map(\.url.path), forKey: storeKey)
    }

    private func restore() {
        for path in defaults.stringArray(forKey: storeKey) ?? [] where FileManager.default.fileExists(atPath: path) {
            hang(URL(fileURLWithPath: path), quietly: true)
        }
    }

    // MARK: Helpers

    private func item(_ id: UUID) -> HangingCapture? {
        items.first { $0.id == id }
    }

    private func play(_ name: String, volume: Float) {
        guard playsSounds, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true
    )

    static func thumbnail(_ url: URL, maxPixelSize: Int = 480) -> NSImage? {
        guard let image = ImageIOService.thumbnail(at: url, maxPixelSize: maxPixelSize) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private static func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
