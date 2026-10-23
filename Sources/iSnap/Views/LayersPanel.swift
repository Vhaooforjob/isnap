import SwiftUI
import UniformTypeIdentifiers

struct LayersPanel: View {
    @ObservedObject var document: EditorDocument
    @State private var dragged: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Toggle("Snap", isOn: $document.snappingEnabled).toggleStyle(.button)
                    .help("Snap to edges, centers and equal spacing. Hold Option to move freely.")
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(document.annotations.reversed()) { layer in
                        HStack(spacing: 5) {
                            Button { document.select(layer.id, extending: NSEvent.modifierFlags.contains(.shift)) } label: {
                                Image(systemName: layer.type.symbol)
                            }.accessibilityLabel("Select \(layer.displayName)")
                                .accessibilityValue(document.selectedAnnotationIDs.contains(layer.id) ? String(localized: "Selected") : "")
                            TextField("Layer name", text: Binding(get: { layer.displayName },
                                set: { document.updateLayer(layer.id, name: $0) })).textFieldStyle(.plain)
                            Button { document.updateLayer(layer.id, hidden: !layer.isHidden) } label: {
                                Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                            }.help("Show or hide layer").accessibilityLabel("Show or hide \(layer.displayName)")
                            Button { document.updateLayer(layer.id, locked: !layer.isLocked) } label: {
                                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                            }.help("Lock or unlock layer").accessibilityLabel("Lock or unlock \(layer.displayName)")
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .padding(8)
                        .background(document.selectedAnnotationIDs.contains(layer.id) ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { document.select(layer.id, extending: NSEvent.modifierFlags.contains(.shift)) }
                        .contextMenu {
                            Button("Bring to Front") { document.select(layer.id); document.reorderSelection(toFront: true) }
                            Button("Send to Back") { document.select(layer.id); document.reorderSelection(toFront: false) }
                        }
                        .onDrag { dragged = layer.id; return NSItemProvider(object: layer.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                            guard let dragged else { return false }
                            document.moveLayer(dragged, before: layer.id); self.dragged = nil; return true
                        }
                    }
                }
            }.frame(minHeight: 100, maxHeight: 190)
            if let item = document.selectedAnnotation {
                LayerGeometry(document: document, item: item).id(item.id)
                    .disabled(item.isLocked)
            }
        }.padding(12)
    }
}

private struct LayerGeometry: View {
    @ObservedObject var document: EditorDocument
    let item: Annotation
    @State private var x = ""
    @State private var y = ""
    @State private var width = ""
    @State private var height = ""
    var body: some View {
        Grid {
            GridRow { Text("X"); field("X", $x); Text("Y"); field("Y", $y) }
            GridRow { Text("W"); field("Width", $width); Text("H"); field("Height", $height) }
        }.font(.caption).onAppear(perform: refresh)
            .onChange(of: item.frame) { _, _ in refresh() }
    }
    private func field(_ name: String, _ value: Binding<String>) -> some View {
        TextField(name, text: value).textFieldStyle(.roundedBorder).onSubmit {
            if let x = Double(x), let y = Double(y), let w = Double(width), let h = Double(height) {
                document.setFrame(CGRect(x: x, y: y, width: w, height: h), for: item.id)
            }
            refresh()
        }
    }
    private func refresh() {
        x = String(format: "%.1f", item.frame.minX); y = String(format: "%.1f", item.frame.minY)
        width = String(format: "%.1f", item.frame.width); height = String(format: "%.1f", item.frame.height)
    }
}
