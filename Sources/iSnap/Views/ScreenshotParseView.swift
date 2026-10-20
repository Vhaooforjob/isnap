import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotParseView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let sourceName: String
    var image: NSImage?
    var regions: [RecognizedRegion] = []
    @State private var selected: Set<UUID> = []
    @State private var preserveLayout = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extracted Text").font(.title2.bold())
                    Text(sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if text.isEmpty {
                ContentUnavailableView(
                    "No Text Found",
                    systemImage: "text.viewfinder",
                    description: Text("The screenshot did not contain text that macOS could recognize.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let image, !regions.isEmpty {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                            ForEach(regions) { region in
                                Button {
                                    if !selected.insert(region.id).inserted { selected.remove(region.id) }
                                } label: {
                                    Rectangle().fill(selected.contains(region.id) ? Color.accentColor.opacity(0.3) : Color.clear)
                                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                                }.buttonStyle(.plain)
                                .frame(width: max(3, region.rect.width * scale), height: max(3, region.rect.height * scale))
                                .offset(x: region.rect.minX * scale, y: region.rect.minY * scale)
                                .help(region.text)
                            }
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(height: 240)
                    HStack {
                        Button("Select All") { selected = Set(regions.map(\.id)) }
                        Button("Deselect") { selected.removeAll() }
                        Toggle("Keep layout", isOn: $preserveLayout)
                        Spacer()
                        Button("Copy Selection") { copy(OCRLayout.plain(chosen, preserveLayout: preserveLayout)) }.disabled(selected.isEmpty)
                        Button("Export CSV…", action: exportCSV)
                    }.controlSize(.small)
                    Text("Click text regions to select them. CSV columns are inferred from their positions; review the result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                HStack {
                    Text("\(text.split(whereSeparator: \.isNewline).count) lines • \(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Text", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: image == nil ? 440 : 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("iSnap", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var chosen: [RecognizedRegion] { selected.isEmpty ? regions : regions.filter { selected.contains($0.id) } }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Extracted.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(OCRLayout.csv(chosen).utf8).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}
