import SwiftUI

struct DraftsView: View {
    var directory: URL = ProjectStore.directory
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("draftRetentionDays") private var retentionDays = 0
    @State private var items: [DraftItem] = []
    @State private var selected: Set<URL> = []
    @State private var confirmingDelete = false
    @State private var renaming: DraftItem?
    @State private var newName = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drafts").font(.title2.bold())
                Text(StorageService.format(items.reduce(0) { $0 + $1.bytes })).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Move old drafts to Trash", selection: $retentionDays) {
                    Text("Never").tag(0)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                }.frame(maxWidth: 330)
                Spacer()
                Button("Select All") { selected = Set(items.map(\.url)) }
                Button("Move to Trash", role: .destructive) { confirmingDelete = true }
                    .disabled(selected.isEmpty || busy)
            }
            Text("Retention runs when iSnap starts or this window opens. The latest recovery session is always kept.")
                .font(.caption).foregroundStyle(.secondary)
            List(items, selection: $selected) { item in
                HStack(spacing: 12) {
                    DraftThumbnail(url: item.url).frame(width: 100, height: 65)
                    VStack(alignment: .leading) {
                        Text(item.name).lineLimit(1)
                        Text(item.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(StorageService.format(item.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rename") { renaming = item; newName = item.name }
                    Button("Open") {
                        model.openProject(at: item.url)
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .tag(item.url)
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20).frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload(prune: true) }
        .confirmationDialog("Move selected drafts to Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                let urls = Array(selected)
                Task { await perform { try await DraftCatalog.shared.trash(urls) } }
            }
        }
        .alert("Rename Draft", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let item = renaming {
                    let name = newName
                    Task { await perform { try await DraftCatalog.shared.rename(item.url, to: name) } }
                }
                renaming = nil
            }
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        busy = true; error = nil
        do { try await action() } catch { self.error = error.localizedDescription }
        await reload()
        busy = false
    }

    private func reload(prune: Bool = false) async {
        do {
            if prune { try await DraftCatalog.shared.prune(days: retentionDays, directory: directory) }
            items = try await DraftCatalog.shared.items(in: directory)
            selected.formIntersection(Set(items.map(\.url)))
            model.drafts = items.map(\.url)
        } catch { self.error = error.localizedDescription }
    }
}

private struct DraftThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "doc.richtext").foregroundStyle(.secondary) }
        }.task(id: url) {
            let result = try? await DraftCatalog.shared.thumbnail(url)
            if !Task.isCancelled { image = result }
        }
    }
}
