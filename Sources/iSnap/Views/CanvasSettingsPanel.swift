import AppKit
import SwiftUI

struct CanvasSettingsPanel: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Output", selection: binding(\.outputRatio)) {
                    ForEach(OutputRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledSlider(title: "Padding", value: binding(\.padding), range: 0...240, suffix: "px")
                LabeledSlider(title: "Inset", value: binding(\.insetPercent), range: 0...50, suffix: "%")
                LabeledSlider(title: "Corners", value: binding(\.cornerRadius), range: 0...80, suffix: "px")
                LabeledSlider(title: "Shadow", value: binding(\.shadowSize), range: 0...60, suffix: "px")
            }
            Section("Background") {
                Toggle("Show background", isOn: binding(\.showBackground))
                if !settings.value.backgroundImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(settings.value.backgroundImages, id: \.self) { url in
                                Button {
                                    updateCanvas { $0.backgroundImageURL = url }
                                } label: {
                                    Group {
                                        if let image = NSImage(contentsOf: url) {
                                            Image(nsImage: image).resizable().scaledToFill()
                                        } else {
                                            Color.gray
                                        }
                                    }
                                    .frame(width: 54, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(document.canvas.backgroundImageURL == url ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove", role: .destructive) { removeBackground(url) }
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("Add Image…", systemImage: "photo.badge.plus", action: addBackground)
                        .disabled(settings.value.backgroundImages.count >= 8)
                    if document.canvas.backgroundImageURL != nil {
                        Button("Use Gradient") { updateCanvas { $0.backgroundImageURL = nil } }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34))], spacing: 8) {
                    ForEach(GradientPreset.presets) { preset in
                        Button {
                            updateCanvas {
                                $0.gradient = preset
                                $0.backgroundImageURL = nil
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(LinearGradient(colors: [Color(nsColor: preset.start.nsColor), Color(nsColor: preset.end.nsColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 30)
                                .overlay {
                                    if document.canvas.gradient == preset {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }
            Section("Watermark") {
                Toggle("Show watermark", isOn: watermarkEnabledBinding)
                if document.canvas.watermark != nil {
                    Picker("Type", selection: watermarkBinding(\.kind)) {
                        Text("Text").tag(WatermarkContentKind.text)
                        Text("Image").tag(WatermarkContentKind.image)
                    }
                    .pickerStyle(.segmented)

                    if document.canvas.watermark?.kind == .text {
                        TextField("Watermark text", text: watermarkBinding(\.text))
                        ColorPicker("Text color", selection: watermarkColorBinding, supportsOpacity: true)
                    } else {
                        if let data = document.canvas.watermark?.imageData,
                           let image = NSImage(data: data) {
                            HStack {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 88, height: 54)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    updateCanvas { $0.watermark?.imageData = nil }
                                }
                            }
                        }
                        Button("Choose Watermark Image…", systemImage: "photo.badge.plus", action: chooseWatermarkImage)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Opacity")
                            Spacer()
                            Text("\(Int(watermarkBinding(\.opacity).wrappedValue * 100))%")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: watermarkBinding(\.opacity), in: 0.05...1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(Int(watermarkBinding(\.sizePercent).wrappedValue))%")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: watermarkBinding(\.sizePercent), in: 5...50, step: 1)
                    }
                    Picker("Position", selection: watermarkBinding(\.placement)) {
                        ForEach(WatermarkPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                }
            }
            Section("Border") {
                Toggle("Enable border", isOn: binding(\.borderEnabled))
                if document.canvas.borderEnabled {
                    ColorPicker("Color", selection: colorBinding(\.borderColor), supportsOpacity: false)
                    LabeledSlider(title: "Weight", value: binding(\.borderWeight), range: 1...50, suffix: "px")
                    Picker("Position", selection: binding(\.borderPosition)) {
                        ForEach(BorderPosition.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 245, idealWidth: 270, maxWidth: 300)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CanvasConfiguration, T>) -> Binding<T> {
        Binding(
            get: { document.canvas[keyPath: keyPath] },
            set: { value in updateCanvas { $0[keyPath: keyPath] = value } }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CanvasConfiguration, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: document.canvas[keyPath: keyPath].nsColor) },
            set: { color in updateCanvas { $0[keyPath: keyPath] = RGBAColor(NSColor(color)) } }
        )
    }

    private var watermarkEnabledBinding: Binding<Bool> {
        Binding(
            get: { document.canvas.watermark != nil },
            set: { enabled in
                updateCanvas { canvas in
                    canvas.watermark = enabled ? (canvas.watermark ?? WatermarkConfiguration()) : nil
                }
            }
        )
    }

    private func watermarkBinding<T>(_ keyPath: WritableKeyPath<WatermarkConfiguration, T>) -> Binding<T> {
        Binding(
            get: { (document.canvas.watermark ?? WatermarkConfiguration())[keyPath: keyPath] },
            set: { value in
                updateCanvas { canvas in
                    var watermark = canvas.watermark ?? WatermarkConfiguration()
                    watermark[keyPath: keyPath] = value
                    canvas.watermark = watermark
                }
            }
        )
    }

    private var watermarkColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: (document.canvas.watermark ?? WatermarkConfiguration()).textColor.nsColor) },
            set: { color in
                updateCanvas { canvas in
                    var watermark = canvas.watermark ?? WatermarkConfiguration()
                    watermark.textColor = RGBAColor(NSColor(color))
                    canvas.watermark = watermark
                }
            }
        )
    }

    private func updateCanvas(_ mutation: (inout CanvasConfiguration) -> Void) {
        document.updateCanvas(mutation)
        settings.value.canvas = document.canvas
    }

    private func addBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try BackgroundImageStore.importImage(from: url)
            settings.value.backgroundImages.append(imported)
            updateCanvas { $0.backgroundImageURL = imported }
        } catch {
            NSSound.beep()
        }
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try BackgroundImageStore.portableImageData(from: url, maxDimension: 1024)
            updateCanvas { canvas in
                var watermark = canvas.watermark ?? WatermarkConfiguration()
                watermark.kind = .image
                watermark.imageData = data
                canvas.watermark = watermark
            }
        } catch {
            NSSound.beep()
        }
    }

    private func removeBackground(_ url: URL) {
        try? BackgroundImageStore.remove(url)
        settings.value.backgroundImages.removeAll { $0 == url }
        if document.canvas.backgroundImageURL == url {
            updateCanvas { $0.backgroundImageURL = nil }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let suffix: String

    init(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, suffix: String) {
        self.title = title
        _value = value
        self.range = range
        self.suffix = suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text("\(Int(value))\(suffix)").foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: range)
        }
    }
}
