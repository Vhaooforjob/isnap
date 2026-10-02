import Carbon
import Foundation

@MainActor
final class GlobalHotkeyService {
    var onHotkey: ((CaptureMode) -> Void)?

    private var references: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x69534E50 // iSNP

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in service.handle(identifier.id) }
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    deinit {
        references.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ settings: AppSettings.HotkeySettings) {
        references.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        references.removeAll()
        register(settings.fullScreen, id: 1)
        register(settings.region, id: 2)
        register(settings.window, id: 3)
    }

    private func register(_ shortcut: String, id: UInt32) {
        guard let parsed = Self.parse(shortcut) else { return }
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: id)
        guard RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &reference) == noErr else {
            return
        }
        references.append(reference)
    }

    private func handle(_ identifier: UInt32) {
        switch identifier {
        case 1: onHotkey?(.fullScreen)
        case 2: onHotkey?(.region)
        case 3: onHotkey?(.window)
        default: break
        }
    }

    static func parse(_ value: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        if value.contains("⌘") || value.localizedCaseInsensitiveContains("cmd") { modifiers |= UInt32(cmdKey) }
        if value.contains("⌃") || value.localizedCaseInsensitiveContains("ctrl") { modifiers |= UInt32(controlKey) }
        if value.contains("⌥") || value.localizedCaseInsensitiveContains("option") || value.localizedCaseInsensitiveContains("alt") { modifiers |= UInt32(optionKey) }
        if value.contains("⇧") || value.localizedCaseInsensitiveContains("shift") { modifiers |= UInt32(shiftKey) }

        let normalized = value
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["cmd", "ctrl", "control", "option", "alt", "shift"].contains($0.lowercased()) }
            .last?
            .uppercased()
        let symbolStripped = value
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let key = normalized.flatMap({ keyCodes[$0] != nil ? $0 : nil }) ?? (keyCodes[symbolStripped] != nil ? symbolStripped : nil),
              let keyCode = keyCodes[key] else { return nil }
        return (keyCode, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16,
        "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32,
        "[": 33, "I": 34, "P": 35, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "SPACE": 49,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111
    ]
}
