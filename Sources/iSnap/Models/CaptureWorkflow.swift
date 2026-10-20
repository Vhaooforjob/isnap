import Foundation

struct CaptureWorkflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Quick Capture"
    var shortcut = "⌃⌥9"
    var region = true
    var presetID: UUID?
    var watermark = ""
    var saves = true
    var copies = true
    var uploadProvider: AppModel.CloudProvider?

    @MainActor static func isValid(_ workflows: [CaptureWorkflow]) -> Bool {
        var keys: Set<String> = []
        return workflows.allSatisfy {
            guard !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let key = GlobalHotkeyService.parse($0.shortcut), key.modifiers != 0 else { return false }
            return keys.insert("\(key.keyCode):\(key.modifiers)").inserted
        }
    }
}
