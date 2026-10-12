import SwiftUI

struct BatchExportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetID: UUID?
    @State private var format = ExportFormat.png
    @State private var quality = 0.95
    @State private var maxDimension = 0
    @State private var prefix = "iSnap"
    @State private var useCurrentCanvas = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Export").font(.title2.bold())
            Text("\(model.batchItems.count) images").foregroundStyle(.secondary)
            Form {
                Picker("Canvas preset", selection: $presetID) {
                    Text("No preset").tag(Optional<UUID>.none)
                    ForEach(model.features.state.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                if presetID == nil { Toggle("Use current editor canvas and watermark", isOn: $useCurrentCanvas) }
                Picker("Format", selection: $format) { Text("PNG").tag(ExportFormat.png); Text("JPEG").tag(ExportFormat.jpeg) }
                if format == .jpeg { Slider(value: $quality, in: 0.1...1) { Text("JPEG quality") } }
                Picker("Maximum dimension", selection: $maxDimension) {
                    Text("Original size").tag(0)
                    ForEach([800, 1280, 1920, 2560, 3840], id: \.self) { Text("\($0) px").tag($0) }
                }
                TextField("Filename prefix", text: $prefix)
                Text("Leave the prefix empty to keep source filenames. Existing files are preserved.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.isBatchExporting)
            if !model.batchProgress.isEmpty { Text(model.batchProgress).font(.callout).textSelection(.enabled) }
            HStack {
                if model.isBatchExporting {
                    ProgressView().controlSize(.small)
                    Button("Stop Export") { model.batchTask?.cancel() }
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(model.isBatchExporting)
                Button("Choose Folder and Export…") { export() }.disabled(model.isBatchExporting)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(model.isBatchExporting)
    }

    private func export() {
        do {
            var canvas = CanvasConfiguration()
            canvas.showBackground = false; canvas.padding = 0; canvas.cornerRadius = 0; canvas.shadowSize = 0
            if let preset = model.features.state.presets.first(where: { $0.id == presetID }) { canvas = try model.resolvedCanvas(for: preset) }
            else if useCurrentCanvas { canvas = model.document.canvas }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            model.batchExport(to: folder, options: BatchExportOptions(canvas: canvas, format: format, quality: quality,
                maxDimension: maxDimension, prefix: prefix))
        } catch { model.errorMessage = error.localizedDescription }
    }
}
