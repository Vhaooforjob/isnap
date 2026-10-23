import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GuideController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var draft = GuideDraft()
    @Published var busy = false
    @Published var message = ""
    @Published var shortcutAvailable = false
    private let service: GuideService
    private let directory: URL
    init(directory: URL = StorageService.appSupport.appendingPathComponent("GuideDraft")) {
        self.directory = directory; self.service = GuideService(directory: directory)
        super.init()
    }
    private let hotkeys = GlobalHotkeyService(signature: 0x69534744)
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var capture: (() async throws -> CGImage?)?
    func show(capture: @escaping () async throws -> CGImage?) {
        self.capture = capture
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = String(localized: "Step Guide"); panel.isReleasedWhenClosed = false
        panel.delegate = self; panel.contentView = NSHostingView(rootView: GuideView(controller: self))
        panel.minSize = CGSize(width: 600, height: 460); panel.center(); panel.makeKeyAndOrderFront(nil); self.panel = panel
        shortcutAvailable = hotkeys.registerActions([("⌃⌥G", { [weak self] in self?.captureStep() })]).isEmpty
        run { self.draft = try await self.service.load() }
    }
    func captureStep() {
        guard !busy, let capture else { return }
        run {
            if let image = try await capture() { self.draft = try await self.service.append(image, draft: self.draft) }
        }
    }
    func importImages() {
        guard !busy else { return }
        let chooser = NSOpenPanel(); chooser.allowedContentTypes = [.png, .jpeg]; chooser.allowsMultipleSelection = true
        guard chooser.runModal() == .OK else { return }; let urls = chooser.urls
        run {
            for url in urls {
                try Task.checkCancellation()
                let image = try await Task.detached { try ImageIOService.fullImage(at: url) }.value
                self.draft = try await self.service.append(image, draft: self.draft)
            }
        }
    }
    func scheduleSave() {
        saveTask?.cancel()
        let value = draft
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); try await service.save(value) }
            catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
    func save() { saveTask?.cancel(); let value = draft; run { try await self.service.save(value) } }
    func move(_ id: UUID, by delta: Int) {
        guard !busy, let i = draft.steps.firstIndex(where: { $0.id == id }), draft.steps.indices.contains(i + delta) else { return }
        draft.steps.swapAt(i, i + delta); save()
    }
    func remove(_ id: UUID) { guard !busy else { return }; draft.steps.removeAll { $0.id == id }; save() }
    func newGuide() {
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Start a new guide?")
        alert.informativeText = String(localized: "Export this draft first if you want to keep it.")
        alert.addButton(withTitle: String(localized: "New Guide")); alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }; draft = GuideDraft(); save()
    }
    func export(pdf: Bool) {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = pdf ? "Guide.pdf" : "Guide"
        if pdf { panel.allowedContentTypes = [.pdf] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let value = draft
        run {
            try await self.service.save(value)
            try await self.service.export(value, to: url, pdf: pdf)
            self.message = String(localized: "Guide exported.")
        }
    }
    func url(_ step: GuideStep) -> URL { directory.appendingPathComponent(step.filename) }
    private func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; saveTask?.cancel(); busy = true; message = ""
        task = Task {
            defer { busy = false }
            do { try await operation() } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        saveTask?.cancel(); hotkeys.unregisterScrollingCapture(); capture = nil; panel = nil
        let value = draft; Task { do { try await service.save(value) } catch { message = error.localizedDescription } }
    }
}

struct GuideView: View {
    @ObservedObject var controller: GuideController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Guide title", text: $controller.draft.title).font(.title2).onSubmit { controller.save() }.disabled(controller.busy)
            Text(controller.shortcutAvailable ? "Press ⌃⌥G in any app to capture another step. The draft is saved on this Mac." : "Use Capture Step to add screenshots. The draft is saved on this Mac.").font(.caption)
            HStack {
                Button("Capture Step", action: controller.captureStep)
                Button("Add Images…", action: controller.importImages)
                Button("New Guide…", action: controller.newGuide)
                Spacer()
                Button("Export Markdown…") { controller.export(pdf: false) }
                Button("Export PDF…") { controller.export(pdf: true) }
            }.disabled(controller.busy)
            ScrollView {
                LazyVStack {
                    ForEach(Array(controller.draft.steps.enumerated()), id: \.element.id) { index, step in
                        HStack {
                            GuideThumbnail(url: controller.url(step)).frame(width: 170, height: 110)
                            Text("\(index + 1)").monospacedDigit()
                            TextField("Step caption", text: Binding(get: { controller.draft.steps.first { $0.id == step.id }?.caption ?? "" }, set: { text in
                                if let i = controller.draft.steps.firstIndex(where: { $0.id == step.id }) { controller.draft.steps[i].caption = text }
                            })).onSubmit { controller.save() }
                            Button { controller.move(step.id, by: -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move step up").disabled(index == 0)
                            Button { controller.move(step.id, by: 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move step down").disabled(index == controller.draft.steps.count - 1)
                            Button(role: .destructive) { controller.remove(step.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove step")
                        }.padding(8).disabled(controller.busy)
                    }
                }
            }
            HStack {
                if controller.busy { ProgressView().controlSize(.small); Button("Cancel", action: controller.cancel) }
                Text(controller.message).font(.caption).textSelection(.enabled)
                Spacer(); Text("\(controller.draft.steps.count) steps")
            }
        }.padding(16).onChange(of: controller.draft) { _, _ in controller.scheduleSave() }
    }
}
private struct GuideThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() } }
            .task(id: url) {
                let cg = await Task.detached { ImageIOService.thumbnail(at: url, maxPixelSize: 340) }.value
                if let cg, !Task.isCancelled { image = NSImage(cgImage: cg, size: .zero) }
            }
    }
}
