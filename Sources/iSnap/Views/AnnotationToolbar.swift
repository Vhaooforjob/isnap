import AppKit
import SwiftUI

struct AnnotationToolbar: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        document.tool = tool
                        if tool != .select { document.selectedAnnotationID = nil }
                    } label: {
                        Image(systemName: tool.symbol).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .tint(document.tool == tool ? .accentColor : nil)
                    .help("\(tool.title) (\(shortcut(for: tool)))")
                }
                Divider().frame(height: 22)
                Button(action: document.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.canUndo)
                Button(action: document.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.canRedo)
                Button(role: .destructive, action: document.deleteSelection) { Image(systemName: "trash") }
                    .disabled(document.selectedAnnotationID == nil)
                if let selected = document.selectedAnnotation,
                   selected.type == .text || selected.type == .number {
                    Button("Edit…", systemImage: "pencil") {
                        document.presentEditor(for: selected)
                    }
                    .help(selected.type == .text ? "Edit text" : "Edit marker style and value")
                }
                Divider().frame(height: 22)
                HStack(spacing: 3) {
                    Button(action: document.zoomPreviewOut) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom out")
                    Button(action: document.resetPreviewZoom) {
                        Text("\(Int((document.previewZoom * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 38)
                    }
                    .help("Fit preview")
                    Button(action: document.zoomPreviewIn) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom in")
                }
                Divider().frame(height: 22)
                ColorPicker("Stroke", selection: strokeBinding, supportsOpacity: true)
                    .labelsHidden().frame(width: 28)
                if supportsFill {
                    ColorPicker("Fill", selection: fillBinding, supportsOpacity: true)
                        .labelsHidden().frame(width: 28)
                }
                HStack(spacing: 4) {
                    Image(systemName: "lineweight")
                    Slider(value: strokeWidthBinding, in: 1...20, step: 1).frame(width: 76)
                    Text("\(Int(strokeWidthBinding.wrappedValue))").monospacedDigit().frame(width: 20)
                }
                .font(.caption)
                if document.tool == .crop {
                    Picker("Ratio", selection: $document.cropAspectRatio) {
                        ForEach(CropAspectRatio.allCases) { Text($0.rawValue).tag($0) }
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(.bar)
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
        }
    }
}
