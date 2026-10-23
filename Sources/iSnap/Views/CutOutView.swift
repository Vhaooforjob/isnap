import SwiftUI

struct CutOutView: View {
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var axis = CutAxis.horizontal
    @State private var start = 0
    @State private var end = 1
    @State private var preview: NSImage?
    @State private var busy = false
    @State private var error = ""
    @State private var task: Task<Void, Never>?
    private var limit: Int { Int(axis == .horizontal ? document.imagePixelSize.height : document.imagePixelSize.width) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cut Out").font(.title2)
            Text("Remove a strip and join the remaining image. Layers outside the strip keep their positions relative to the image. A cut crossing artwork, rotated layers, spotlights or magnifiers flattens the visible artwork. Undo restores the original image and editable layers.")
                .font(.callout)
            Picker("Direction", selection: $axis) { ForEach(CutAxis.allCases) { Text($0.title).tag($0) } }
            HStack {
                VStack(alignment: .leading) { Text("From pixel").font(.caption); TextField("From pixel", value: $start, format: .number) }
                VStack(alignment: .leading) { Text("To pixel (excluded)").font(.caption); TextField("To pixel (excluded)", value: $end, format: .number) }
            }.textFieldStyle(.roundedBorder)
            GeometryReader { geometry in
                if let image = preview ?? document.image {
                    let size = document.imagePixelSize
                    let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width * scale, height: size.height * scale)
                        Rectangle().fill(.red.opacity(0.45))
                            .frame(width: (axis == .horizontal ? size.width : CGFloat(max(0, end - start))) * scale,
                                   height: (axis == .horizontal ? CGFloat(max(0, end - start)) : size.height) * scale)
                            .offset(x: axis == .vertical ? CGFloat(start) * scale : 0, y: axis == .horizontal ? CGFloat(start) * scale : 0)
                    }.clipped().accessibilityLabel("Preview of the strip to remove")
                }
            }.frame(height: 280)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || start < 0 || end <= start || end > limit || end - start >= limit)
            }
        }.padding(20).frame(width: 600)
        .onAppear { start = limit / 3; end = limit / 2 }
        .task {
            guard let image = document.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            do {
                let output = try await BackgroundExportService().render(ImageRenderSnapshot(image: image,
                    annotations: document.annotations, canvas: .sourcePixels, includeBackground: false), format: .png, quality: 1)
                try Task.checkCancellation()
                preview = NSImage(cgImage: output.image, size: .zero)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onChange(of: axis) { _, _ in start = limit / 3; end = max(start + 1, limit / 2) }
        .onDisappear { task?.cancel() }
    }
    private func apply() {
        guard let original = document.image, let image = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        busy = true; error = ""
        let annotations = document.annotations, axis = axis, start = start, end = end
        task = Task {
            defer { busy = false }
            do {
                let result = try await CutOutService().apply(image: image, annotations: annotations, axis: axis, start: start, end: end)
                try Task.checkCancellation()
                guard document.image === original, document.annotations == annotations else { return }
                document.applyCutOut(result); dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
