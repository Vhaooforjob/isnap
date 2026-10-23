import AppKit

enum ScrollEventError: LocalizedError {
    case permission
    var errorDescription: String? {
        String(localized: "Allow iSnap in System Settings → Privacy & Security → Accessibility to scroll automatically, or turn off automatic scrolling and scroll manually.")
    }
}

@MainActor
enum ScrollEventService {
    static func scroll(_ selection: ScreenSelection, direction: ScrollDirection = .down) async throws {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { throw ScrollEventError.permission }
        guard NSScreen.screens.contains(where: { $0.displayID == selection.displayID }) else { throw CaptureError.displayUnavailable }
        try Task.checkCancellation()
        let display = CGDisplayBounds(selection.displayID)
        let point = CGPoint(x: display.minX + selection.rect.midX, y: display.minY + selection.rect.midY)
        let horizontal = direction == .left || direction == .right
        let amount = Int32(max(1, (horizontal ? selection.rect.width : selection.rect.height) * 0.55)) * (direction == .up || direction == .left ? 1 : -1)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: horizontal ? 0 : amount, wheel2: horizontal ? amount : 0, wheel3: 0) else { throw CaptureError.displayUnavailable }
        event.location = point
        event.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(500))
    }
}
