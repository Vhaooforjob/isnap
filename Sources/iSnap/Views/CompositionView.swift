import SwiftUI
import UniformTypeIdentifiers

struct CompositionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var pages: [CompositionPage]
    @State private var options = CompositionOptions()
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Combine Images / PDF").font(.title2.bold())
                Spacer()
                Button("Add Images…", action: addImages).disabled(busy)
                Button("Done") { dismiss() }.disabled(busy)
            }
            List {
                ForEach($pages) { $page in
                    HStack {
                        Text(page.url.lastPathComponent).lineLimit(1).frame(width: 170, alignment: .leading)
                        TextField("Caption", text: $page.caption)
                        Button { move(page.id, by: -1) } label: { Image(systemName: "arrow.up") }
                        Button { move(page.id, by: 1) } label: { Image(systemName: "arrow.down") }
                        Button { pages.removeAll { $0.id == page.id } } label: { Image(systemName: "minus.circle") }
                    }.disabled(busy)
                }.onMove { pages.move(fromOffsets: $0, toOffset: $1) }
            }.frame(minHeight: 220)
            HStack {
                Picker("Direction", selection: $options.horizontal) {
                    Text("Vertical").tag(false); Text("Horizontal").tag(true)
                }
                Picker("Image size", selection: $options.crossDimension) {
                    Text("800 px").tag(CGFloat(800)); Text("1600 px").tag(CGFloat(1600)); Text("2400 px").tag(CGFloat(2400))
                }
                Stepper("Spacing \(Int(options.spacing)) px", value: $options.spacing, in: 0...200, step: 8)
            }.disabled(busy)
            Toggle("Include captions", isOn: $options.captions).disabled(busy)
            Text("PDF uses one image per page in the displayed order. Combined images can be annotated in the editor.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if busy { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } }
                Spacer()
                Button("Open Combined Image") { run(pdf: false, target: nil) }.disabled(pages.isEmpty || busy)
                Button("Export PNG…") { choose(pdf: false) }.disabled(pages.isEmpty || busy)
                Button("Export PDF…") { choose(pdf: true) }.disabled(pages.isEmpty || busy)
            }
        }.padding(20).frame(width: 760, height: 480).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(busy)
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard pages.indices.contains(target) else { return }
        pages.swapAt(index, target)
    }
    private func addImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        pages += panel.urls.map { CompositionPage(url: $0, caption: $0.deletingPathExtension().lastPathComponent) }
    }
    private func choose(pdf: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = pdf ? [.pdf] : [.png]
        panel.nameFieldStringValue = pdf ? "Screenshots.pdf" : "Combined.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(pdf: pdf, target: url)
    }
    private func run(pdf: Bool, target: URL?) {
        let pages = pages, options = options
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                let service = CompositionService()
                if pdf, let target {
                    let data = try await service.pdf(pages, captions: options.captions)
                    try await model.backgroundExporter.write(data, to: target, overwrite: true)
                } else {
                    let image = try await service.combine(pages, options: options)
                    try Task.checkCancellation()
                    if let target {
                        let snapshot = ImageRenderSnapshot(image: image, annotations: [], canvas: {
                            var value = CanvasConfiguration(); value.cornerRadius = 0; value.shadowSize = 0; return value
                        }(), includeBackground: false)
                        let output = try await model.backgroundExporter.render(snapshot, format: .png, quality: 1)
                        try await model.backgroundExporter.write(output.data, to: target, overwrite: true)
                    } else {
                        guard model.loadIntoEditor(CaptureResult(image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)),
                            sourceName: String(localized: "Combined Images"))) else { return }
                        dismiss()
                    }
                }
                model.statusText = String(localized: "Composition completed")
            } catch is CancellationError { error = String(localized: "Cancelled") }
            catch { self.error = error.localizedDescription }
        }
    }
}
