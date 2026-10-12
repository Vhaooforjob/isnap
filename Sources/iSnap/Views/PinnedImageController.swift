import AppKit
import SwiftUI

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    private var panels: [NSPanel] = []

    func pin(_ image: NSImage, title: String) {
        let size = image.size
        let scale = min(1, 640 / max(1, size.width), 480 / max(1, size.height))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: max(260, size.width * scale), height: max(160, size.height * scale) + 44),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 260, height: 160)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PinnedImageView(image: image, panel: panel))
        panel.center()
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + CGFloat(panels.count % 6) * 24, y: panel.frame.minY - CGFloat(panels.count % 6) * 24))
        panels.append(panel)
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        panels.removeAll { $0 === window }
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    weak var panel: NSPanel?
    @State private var opacity = 1.0
    @State private var locked = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $opacity, in: 0.2...1).frame(maxWidth: 150)
                    .help("Image opacity")
                    .onChange(of: opacity) { _, value in panel?.alphaValue = value }
                Spacer()
                Toggle(isOn: $locked) { Image(systemName: locked ? "lock.fill" : "lock.open") }
                    .toggleStyle(.button)
                    .help("Lock position and size")
                    .onChange(of: locked) { _, value in
                        panel?.isMovable = !value
                        if value { panel?.styleMask.remove(.resizable) }
                        else { panel?.styleMask.insert(.resizable) }
                    }
                Button { panel?.close() } label: { Image(systemName: "xmark") }
                    .help("Close pinned image")
            }
            .controlSize(.small).padding(8).background(.bar)
        }
    }
}
