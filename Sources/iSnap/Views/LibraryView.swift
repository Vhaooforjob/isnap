import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: Set<URL> = []
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var days = 0
    @State private var isConfirmingDelete = false
    @State private var deletionItems: [LibraryItem] = []
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)]

    private var filtered: [LibraryItem] {
        model.libraryItems.filter { item in
            let metadata = model.features.metadata(for: item.url)
            if favoritesOnly && !metadata.favorite { return false }
            if days > 0 && item.modifiedAt < Calendar.current.date(byAdding: .day, value: -days, to: Date())! { return false }
            let haystack = [item.name, metadata.tags.joined(separator: " "), model.indexedText[item.url] ?? ""].joined(separator: " ")
            return query.isEmpty || haystack.localizedStandardContains(query)
        }
    }
    private var selection: [LibraryItem] { filtered.filter { selected.contains($0.url) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Screenshot Library").font(.title2.bold())
                Text("\(filtered.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder", systemImage: "folder") { model.revealLibrary() }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reloadLibrary() } }
            }.padding()
            HStack {
                TextField("Search filenames, tags, or text in images", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Favorites", isOn: $favoritesOnly).toggleStyle(.button)
                Picker("Modified", selection: $days) {
                    Text("All dates").tag(0)
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                }.frame(width: 180)
            }.padding(.horizontal).padding(.bottom, 8)
            HStack {
                Button("Select All") { selected = Set(filtered.map(\.url)) }
                Button("Deselect") { selected.removeAll() }.disabled(selected.isEmpty)
                Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit Tags") { model.editTags(for: selection) }.disabled(selection.isEmpty)
                Button("Batch Export…") {
                    model.batchItems = selection
                    model.isShowingBatchExport = true
                }.disabled(selection.isEmpty || model.isBatchExporting)
                Button("Move to Trash", role: .destructive) { confirmDelete(selection) }.disabled(selection.isEmpty)
            }.controlSize(.small).padding(.horizontal).padding(.bottom, 8)
            if model.isIndexing || !model.indexingProgress.isEmpty {
                HStack {
                    if model.isIndexing { ProgressView().controlSize(.small) }
                    Text(model.indexingProgress).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("No Matching Screenshots", systemImage: "photo.stack",
                    description: Text("Capture an image or adjust the search and filters."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                LibraryCard(item: item, isSelected: selected.contains(item.url))
                                    .onTapGesture(count: 2) { model.openLibraryItem(item) }
                                    .onTapGesture {
                                        if NSEvent.modifierFlags.contains(.command) {
                                            if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
                                        } else { selected = [item.url] }
                                    }
                                HStack {
                                    Toggle("Select", isOn: Binding(
                                        get: { selected.contains(item.url) },
                                        set: { if $0 { selected.insert(item.url) } else { selected.remove(item.url) } }
                                    )).labelsHidden().help("Select image")
                                    Text(model.features.metadata(for: item.url).tags.joined(separator: ", "))
                                        .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { model.toggleFavorite(item) } label: {
                                        Image(systemName: model.features.metadata(for: item.url).favorite ? "star.fill" : "star")
                                    }.buttonStyle(.borderless).help("Toggle favorite")
                                }.padding(.horizontal, 8)
                            }
                            .contextMenu {
                                Button("Open in Editor") { model.openLibraryItem(item) }
                                Button("Pin on Screen") { model.pinImage(at: item.url) }
                                Button("Edit Tags") { model.editTags(for: [item]) }
                                Button("Share…") { model.showShareMenu(for: item.url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { confirmDelete([item]) }
                            }
                        }
                    }.padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.reloadLibrary() }
        .onChange(of: model.libraryItems) { _, items in selected.formIntersection(Set(items.map(\.url))) }
        .onDeleteCommand { confirmDelete(selection) }
        .confirmationDialog("Move selected screenshots to Trash?", isPresented: $isConfirmingDelete) {
            Button("Move \(deletionItems.count) Screenshots to Trash", role: .destructive) {
                let items = deletionItems
                Task { await model.deleteLibraryItems(items) }
                selected.subtract(items.map(\.url))
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can recover these images from the Trash.") }
    }

    private func confirmDelete(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        deletionItems = items; isConfirmingDelete = true
    }
}

private struct LibraryCard: View {
    let item: LibraryItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryThumbnail(item: item, maxPixelSize: 520, placeholder: "photo.badge.exclamationmark")
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 160)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
            HStack {
                Text("\(Int(item.dimensions.width)) × \(Int(item.dimensions.height))")
                Spacer()
                Text(item.modifiedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}
