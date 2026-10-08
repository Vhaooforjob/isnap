import AppKit
import SwiftUI

struct AnnotationToolbar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    @State private var isShowingControls = false
    @State private var isShowingStickers = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar.fixedSize(horizontal: true, vertical: false)
            compactToolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var fullToolbar: some View {
        HStack(spacing: 6) {
            toolButtons
            Divider().frame(height: 22)
            historyControls
            editButton(compact: false)
            Divider().frame(height: 22)
            documentActions(compact: false)
            Divider().frame(height: 22)
            zoomControls
            Divider().frame(height: 22)
            styleControls
            contextControls
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 4) {
            toolButtons
            Divider().frame(height: 22)
            historyControls
            editButton(compact: true)
            Divider().frame(height: 22)
            documentActions(compact: true)
            Divider().frame(height: 22)
            zoomControls
            Button {
                isShowingControls.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Style and selection controls")
            .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Controls").font(.headline)
                    styleControls
                    contextControls
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(14)
                .frame(minWidth: 250)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var toolButtons: some View {
        ForEach(EditorTool.allCases.filter { $0 != .image }) { tool in
            Button {
                document.tool = tool
                if tool != .select { document.selectedAnnotationID = nil }
            } label: {
                Image(systemName: tool.symbol).frame(width: 18, height: 18)
            }
            .tint(document.tool == tool ? .accentColor : nil)
            .help("\(tool.title) (\(shortcut(for: tool)))")
        }
    }

    @ViewBuilder
    private var historyControls: some View {
        Button(action: document.undo) { Image(systemName: "arrow.uturn.backward") }
            .disabled(!document.canUndo)
            .help("Undo")
        Button(action: document.redo) { Image(systemName: "arrow.uturn.forward") }
            .disabled(!document.canRedo)
            .help("Redo")
        Button(role: .destructive, action: document.deleteSelection) { Image(systemName: "trash") }
            .disabled(document.selectedAnnotationID == nil)
            .help("Delete selected annotation")
    }

    @ViewBuilder
    private func editButton(compact: Bool) -> some View {
        if let selected = document.selectedAnnotation,
           selected.type == .text || selected.type == .number {
            Button {
                document.presentEditor(for: selected)
            } label: {
                if compact { Image(systemName: "pencil") } else { Label("Edit…", systemImage: "pencil") }
            }
            .help(selected.type == .text ? String(localized: "Edit text") : String(localized: "Edit marker style and value"))
        }
    }

    @ViewBuilder
    private func documentActions(compact: Bool) -> some View {
        Button(action: model.insertOverlayImage) {
            if compact { Image(systemName: "photo.badge.plus") } else { Label("Insert Image", systemImage: "photo.badge.plus") }
        }
        .disabled(document.image == nil)
        .help("Insert an image overlay")
        Button {
            isShowingStickers.toggle()
        } label: {
            if compact { Image(systemName: "face.smiling") } else { Label("Sticker", systemImage: "face.smiling") }
        }
        .disabled(document.image == nil)
        .help("Add a sticker")
        .popover(isPresented: $isShowingStickers, arrowEdge: .bottom) {
            StickerPicker { sticker in
                model.insertSticker(sticker)
                isShowingStickers = false
            }
        }
        Button(action: model.copy) {
            if compact { Image(systemName: "doc.on.doc") } else { Label("Copy", systemImage: "doc.on.doc") }
        }
        .disabled(document.image == nil)
        .help("Copy edited image (\(model.settings.value.hotkeys.copyEditedImage))")
        Button(action: model.quickSave) {
            if compact { Image(systemName: "square.and.arrow.down") } else { Label("Save", systemImage: "square.and.arrow.down") }
        }
        .disabled(document.image == nil)
        .help("Save edited image (\(model.settings.value.hotkeys.saveEditedImage))")
    }

    private var zoomControls: some View {
        HStack(spacing: 3) {
            Button(action: document.zoomPreviewOut) { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button(action: document.resetPreviewZoom) {
                Text("\(Int((document.previewZoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .help("Fit preview")
            Button(action: document.zoomPreviewIn) { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if document.selectedAnnotation?.type == .image {
            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: imageOpacityBinding, in: 0.05...1).frame(width: 86)
                Text("\(Int(imageOpacityBinding.wrappedValue * 100))%")
                    .monospacedDigit().frame(width: 34)
            }
            .font(.caption)
            .help("Overlay opacity")
        } else {
            HStack(spacing: 6) {
                ColorPicker("Stroke", selection: strokeBinding, supportsOpacity: true)
                    .labelsHidden().frame(width: 28)
                if supportsFill {
                    ColorPicker("Fill", selection: fillBinding, supportsOpacity: true)
                        .labelsHidden().frame(width: 28)
                }
                Image(systemName: "lineweight")
                Slider(value: strokeWidthBinding, in: 1...20, step: 1).frame(width: 76)
                Text("\(Int(strokeWidthBinding.wrappedValue))").monospacedDigit().frame(width: 20)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var contextControls: some View {
        if document.tool == .crop {
            Picker("Ratio", selection: $document.cropAspectRatio) {
                ForEach(CropAspectRatio.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 100)
            Button("Apply", action: document.applyCrop).disabled(document.cropRect == nil)
            if document.isCropApplied { Button("Reset", action: document.resetCrop) }
        }
        if let selected = document.selectedAnnotation {
            HStack(spacing: 4) {
                Image(systemName: "rotate.right")
                Slider(value: rotationBinding(selected), in: -180...180, step: 1).frame(width: 72)
            }
        }
    }

    private var supportsFill: Bool {
        let type = document.selectedAnnotation?.type ?? document.tool
        return type == .rectangle || type == .ellipse
    }

    private var strokeBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: document.selectedAnnotation?.stroke.nsColor ?? document.style.stroke.nsColor) },
            set: { color in updateColor(color, isFill: false) }
        )
    }

    private var fillBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: document.selectedAnnotation?.fill.nsColor ?? document.style.fill.nsColor) },
            set: { color in updateColor(color, isFill: true) }
        )
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { Double(document.selectedAnnotation?.strokeWidth ?? document.style.strokeWidth) },
            set: { value in
                if var item = document.selectedAnnotation {
                    item.strokeWidth = value
                    document.update(item, checkpoint: true)
                } else { document.style.strokeWidth = value }
            }
        )
    }

    private var imageOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(document.selectedAnnotation?.effectiveImageOpacity ?? 1) },
            set: { value in
                guard var item = document.selectedAnnotation, item.type == .image else { return }
                item.imageOpacity = value
                document.update(item, checkpoint: true)
            }
        )
    }

    private func rotationBinding(_ annotation: Annotation) -> Binding<Double> {
        Binding(
            get: { Double(document.selectedAnnotation?.rotation ?? annotation.rotation) },
            set: { value in
                guard var item = document.selectedAnnotation else { return }
                item.rotation = value
                document.update(item, checkpoint: true)
            }
        )
    }

    private func updateColor(_ color: Color, isFill: Bool) {
        let rgba = RGBAColor(NSColor(color))
        if var item = document.selectedAnnotation {
            if isFill { item.fill = rgba } else { item.stroke = rgba }
            document.update(item, checkpoint: true)
        } else if isFill {
            document.style.fill = rgba
        } else {
            document.style.stroke = rgba
        }
    }

    private func shortcut(for tool: EditorTool) -> String {
        switch tool {
        case .select: "V"
        case .crop: "C"
        case .rectangle: "R"
        case .ellipse: "E"
        case .arrow: "A"
        case .line: "L"
        case .text: "T"
        case .spotlight: "S"
        case .number: "N"
        case .image: "—"
        }
    }
}

private struct StickerPicker: View {
    let onSelect: (StickerPreset) -> Void
    private let columns = Array(repeating: GridItem(.fixed(42), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Sticker").font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(StickerPreset.all) { sticker in
                    Button {
                        onSelect(sticker)
                    } label: {
                        Text(sticker.emoji)
                            .font(.system(size: 25))
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .help(sticker.localizedName)
                }
            }
        }
        .padding(14)
    }
}
