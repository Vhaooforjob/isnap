import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSnap", isDirectory: true)
        fileURL = base.appendingPathComponent("settings.json")
        do {
            let data = try Data(contentsOf: fileURL)
            value = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            value = AppSettings()
        }
    }

    func saveNow() throws {
        let data = try JSONEncoder.pretty.encode(value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? self?.saveNow()
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

