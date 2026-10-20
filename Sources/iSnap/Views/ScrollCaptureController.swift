import AppKit
import SwiftUI

@MainActor
final class ScrollCaptureController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var frames: [CGImage] = []
    @Published private(set) var overlaps: [Int] = []
    @Published private(set) var pending: CGImage?
    @Published var overlap = 0
    @Published var message = ""
    @Published var busy = false
    @Published var preview: NSImage?
    @Published var seamPreview: NSImage?
    @Published var trimTop = 0
    @Published var trimBottom = 0
    @Published var scrollBeforeCapture = false
    @Published var shortcutAvailable = false
    private var panel: NSPanel?
    private var capture: (() async throws -> CGImage)?
    private var completion: ((NSImage?) -> Void)?
    private var activeTask: Task<Void, Never>?
    private var scroll: (() async throws -> Void)?
    private let hotkeys = GlobalHotkeyService(signature: 0x69534E53)

    func begin(first: CGImage, capture: @escaping () async throws -> CGImage,
               scroll: (() async throws -> Void)? = nil, completion: @escaping (NSImage?) -> Void) {
        frames = [first]; overlaps = []; pending = nil; overlap = 0; message = ""; busy = false
        trimTop = 0; trimBottom = 0; scrollBeforeCapture = false; seamPreview = nil
        self.scroll = scroll
        shortcutAvailable = hotkeys.registerScrollingCapture { [weak self] in self?.captureNext() }
        self.capture = capture; self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 800),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Scrolling Capture")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 500)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScrollCaptureView(controller: self))
        self.panel = panel
        panel.center(); panel.orderFrontRegardless()
        refreshPreview()
    }

    func captureNext() {
        guard !busy, pending == nil, let capture else { return }
        busy = true
        message = ""
        panel?.orderOut(nil)
        activeTask = Task {
            do {
                if scrollBeforeCapture { try await scroll?() }
                try Task.checkCancellation()
                let next = try await capture()
                try Task.checkCancellation()
                guard let previous = frames.last, next.width == previous.width, next.height == previous.height else {
                    throw StitchError.incompatibleFrames
                }
                let previousContent = try ScrollingStitcher.trim(previous, top: trimTop, bottom: trimBottom)
                let nextContent = try ScrollingStitcher.trim(next, top: trimTop, bottom: trimBottom)
                let estimate = await Task.detached(priority: .userInitiated) {
                    ScrollingStitcher.estimateOverlap(previous: previousContent, next: nextContent)
                }.value
                try Task.checkCancellation()
                pending = next
                overlap = estimate ?? nextContent.height / 3
                message = estimate == nil
                    ? String(localized: "No reliable match. Adjust overlap and review the seam before adding.")
                    : String(localized: "Overlap detected. Review the seam before adding.")
                refreshPreview()
            } catch is CancellationError { return }
            catch { message = error.localizedDescription }
            busy = false
            panel?.orderFrontRegardless()
        }
    }

    func addPending() {
        guard let pending else { return }
        guard let content = try? ScrollingStitcher.trim(pending, top: trimTop, bottom: trimBottom),
              overlap >= 0, overlap < content.height else {
            message = StitchError.incompatibleFrames.localizedDescription; return
        }
        let candidateFrames = frames + [pending]
        let candidateOverlaps = overlaps + [overlap]
        let totalHeight = candidateFrames.reduce(0) { $0 + $1.height - trimTop - trimBottom } - candidateOverlaps.reduce(0, +)
        guard totalHeight <= 60_000, pending.width * totalHeight <= 80_000_000 else {
            message = StitchError.tooLarge.localizedDescription; return
        }
        frames = candidateFrames; overlaps = candidateOverlaps
        self.pending = nil; message = ""; refreshPreview()
    }

    func discardPending() { pending = nil; message = ""; refreshPreview() }
    func removeLast() {
        guard frames.count > 1 else { return }
        frames.removeLast(); overlaps.removeLast(); refreshPreview()
    }

    func refreshPreview() {
        let allFrames: [CGImage]
        do { allFrames = try (frames + (pending.map { [$0] } ?? [])).map { try ScrollingStitcher.trim($0, top: trimTop, bottom: trimBottom) } }
        catch { preview = nil; seamPreview = nil; message = error.localizedDescription; return }
        let allOverlaps = overlaps + (pending == nil ? [] : [overlap])
        guard let first = allFrames.first else { return }
        let scale = min(1, 360.0 / Double(first.width))
        let thumbnails = allFrames.compactMap { image -> CGImage? in
            let width = max(1, Int(Double(image.width) * scale))
            let height = max(1, Int(Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        do {
            let image = try ScrollingStitcher.stitch(thumbnails, overlaps: allOverlaps.map { Int(Double($0) * scale) })
            preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            seamPreview = nil
            if pending != nil, allFrames.count >= 2 {
                let seam = try ScrollingStitcher.seam(previous: allFrames[allFrames.count - 2], next: allFrames.last!, overlap: overlap)
                seamPreview = NSImage(cgImage: seam, size: CGSize(width: seam.width, height: seam.height))
            }
        } catch { message = error.localizedDescription }
    }

    func finish() {
        guard !busy, pending == nil else { return }
        busy = true
        let frames = frames, overlaps = overlaps, top = trimTop, bottom = trimBottom
        activeTask = Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try ScrollingStitcher.stitch(frames.map { try ScrollingStitcher.trim($0, top: top, bottom: bottom) }, overlaps: overlaps)
                }.value
                try Task.checkCancellation()
                end(NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
            } catch is CancellationError { return }
            catch { busy = false; message = error.localizedDescription }
        }
    }

    func cancel() { activeTask?.cancel(); end(nil) }
    private func end(_ image: NSImage?) {
        let callback = completion
        completion = nil; capture = nil
        scroll = nil
        hotkeys.unregisterScrollingCapture()
        panel?.orderOut(nil); panel = nil
        frames = []; overlaps = []; pending = nil; preview = nil; seamPreview = nil; busy = false
        callback?(image)
    }
    func windowWillClose(_ notification: Notification) { cancel() }
}

private struct ScrollCaptureView: View {
    @ObservedObject var controller: ScrollCaptureController
    @State private var seamZoom = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scroll down in the source app, leaving part of the previous capture visible, then capture the next frame.")
                .font(.callout)
            HStack {
                Text("Ignore fixed areas (px)")
                TextField("Top", value: $controller.trimTop, format: .number).frame(width: 55)
                    .help("Remove fixed header from every frame")
                TextField("Bottom", value: $controller.trimBottom, format: .number).frame(width: 55)
                    .help("Remove fixed footer from every frame")
            }.disabled(controller.frames.count > 1 || controller.pending != nil || controller.busy)
            .onChange(of: controller.trimTop) { _, _ in controller.refreshPreview() }
            .onChange(of: controller.trimBottom) { _, _ in controller.refreshPreview() }
            Toggle("Scroll automatically before the next capture", isOn: $controller.scrollBeforeCapture)
                .disabled(controller.busy)
            Text(controller.shortcutAvailable ? "Capture from any app with ⌃⌥N." : "⌃⌥N is unavailable. Use Capture Next.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if let image = controller.preview { Image(nsImage: image).resizable().scaledToFit() }
            }.background(.black.opacity(0.1))
            if let pending = controller.pending {
                if let seam = controller.seamPreview {
                    HStack {
                        Text("Seam detail")
                        Slider(value: $seamZoom, in: 0.5...3)
                        Text("\(Int(seamZoom * 100))%").monospacedDigit()
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: seam).resizable()
                            .frame(width: seam.size.width * seamZoom, height: seam.size.height * seamZoom)
                            .overlay(alignment: .top) {
                                Rectangle().fill(.orange).frame(height: 1)
                                    .offset(y: CGFloat(min(80, (controller.frames.last?.height ?? 80) - controller.trimTop - controller.trimBottom)) * seamZoom)
                            }
                    }.frame(height: 150)
                }
                HStack {
                    Text("Overlap (px)")
                    TextField("Overlap", value: $controller.overlap, format: .number).frame(width: 70)
                        .onChange(of: controller.overlap) { _, value in
                            controller.overlap = value.clamped(to: 0...max(0, pending.height - controller.trimTop - controller.trimBottom - 1))
                            controller.refreshPreview()
                        }
                    Stepper("", value: $controller.overlap, in: 0...max(0, pending.height - controller.trimTop - controller.trimBottom - 1)).labelsHidden()
                }
                HStack {
                    Button("Add Frame", action: controller.addPending)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Discard Frame", action: controller.discardPending)
                }
            }
            if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("\(controller.frames.count) frames").font(.caption)
                Spacer()
                Button("Remove Last", action: controller.removeLast)
                    .disabled(controller.frames.count < 2 || controller.pending != nil || controller.busy)
            }
            HStack {
                Button("Cancel", action: controller.cancel)
                Spacer()
                Button("Capture Next", action: controller.captureNext)
                    .disabled(controller.busy || controller.pending != nil)
                Button("Finish", action: controller.finish)
                    .disabled(controller.busy || controller.pending != nil)
            }
            if controller.busy { ProgressView().controlSize(.small) }
        }.padding(16)
    }
}
