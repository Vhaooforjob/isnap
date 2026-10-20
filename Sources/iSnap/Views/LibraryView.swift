import SwiftUI
import QuickLookUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: Set<URL> = []
    @State private var query = ""
    @State private var searchQuery = ""
    @State private var sort = LibrarySort.newest
    @State private var anchor: URL?
    @State private var cursor: URL?
    @State private var previewURL: URL?
    @State private var columnCount = 1
    @FocusState private var gridFocused: Bool
    @State private var favoritesOnly = false
    @State private var days = 0
    @State private var isConfirmingDelete = false
    @State private var deletionItems: [LibraryItem] = []
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)]

    private var filtered: [LibraryItem] {
        sort.sorted(model.libraryItems.filter { item in
            let metadata = model.features.metadata(for: item.url)
            if favoritesOnly && !metadata.favorite { return false }
            if days > 0 && item.modifiedAt < Calendar.current.date(byAdding: .day, value: -days, to: Date())! { return false }
            let haystack = [item.name, metadata.tags.joined(separator: " "), model.indexedText[item.url] ?? ""].joined(separator: " ")
            return searchQuery.isEmpty || haystack.localizedStandardContains(searchQuery)
        })
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
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }.frame(width: 175)
            }.padding(.horizontal).padding(.bottom, 8)
            HStack {
                Button("Select All") { selected = Set(filtered.map(\.url)) }
                Button("Deselect") { selected.removeAll() }.disabled(selected.isEmpty)
                Button("Quick Look") { previewURL = selectedPreviewURL }.disabled(selection.isEmpty)
                Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit Tags") { model.editTags(for: selection) }.disabled(selection.isEmpty)
                Button("Combine / PDF…") {
                    model.compositionPages = selection.map { CompositionPage(url: $0.url, caption: $0.name) }
                    model.isShowingComposition = true
                }.disabled(selection.isEmpty)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                LibraryCard(item: item, isSelected: selected.contains(item.url))
                                    .onTapGesture(count: 2) { model.openLibraryItem(item) }
                                    .onTapGesture {
                                        select(item.url, extending: NSEvent.modifierFlags.contains(.shift),
                                            toggling: NSEvent.modifierFlags.contains(.command))
                                        gridFocused = true
                                    }
                                if let snippet = LibraryNavigation.snippet(model.indexedText[item.url] ?? "", query: searchQuery) {
                                    Text(highlight(snippet)).font(.caption).lineLimit(3).padding(.horizontal, 8)
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
                            .id(item.url)
                            .contextMenu {
                                Button("Open in Editor") { model.openLibraryItem(item) }
                                Button("Quick Look") { previewURL = item.url }
                                Button("Pin on Screen") { model.pinImage(at: item.url) }
                                Button("Edit Tags") { model.editTags(for: [item]) }
                                Button("Share…") { model.showShareMenu(for: item.url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { confirmDelete([item]) }
                            }
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { updateColumns(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                    })
                    .padding(20)
                }
                .focusable().focused($gridFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .space, .return]) { key in
                    handleKey(key)
                }
                .onChange(of: cursor) { _, url in if let url { proxy.scrollTo(url) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.reloadLibrary() }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(180)); searchQuery = query }
            catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reloadLibrary() }
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let url = previewURL {
                LibraryQuickLook(url: url, previous: { navigatePreview(-1) }, next: { navigatePreview(1) },
                    close: { previewURL = nil })
            }
        }
        .onChange(of: filtered.map(\.url)) { _, urls in
            selected.formIntersection(Set(urls))
            if let cursor, !urls.contains(cursor) { self.cursor = nil }
            if let anchor, !urls.contains(anchor) { self.anchor = nil }
            if let previewURL, !urls.contains(previewURL) { self.previewURL = nil }
        }
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

    private func updateColumns(_ width: CGFloat) {
        columnCount = max(1, Int((width + CGFloat(16)) / CGFloat(196)))
    }

    private func navigatePreview(_ offset: Int) {
        let items = filtered
        guard let index = items.firstIndex(where: { $0.url == previewURL }) else { return }
        select(items[(index + offset).clamped(to: 0...(items.count - 1))].url)
    }

    private func select(_ url: URL, extending: Bool = false, toggling: Bool = false) {
        if extending {
            if anchor == nil { anchor = cursor ?? url }
            selected = LibraryNavigation.range(from: anchor, to: url, in: filtered.map(\.url))
        } else if toggling {
            if !selected.insert(url).inserted { selected.remove(url) }
            anchor = url
        } else {
            selected = [url]; anchor = url
        }
        cursor = url
        if previewURL != nil { previewURL = url }
    }

    private var selectedPreviewURL: URL? {
        if let cursor, selected.contains(cursor) { return cursor }
        return selection.first?.url
    }

    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        let items = filtered
        guard !items.isEmpty else { return .ignored }
        if key.key == .space { previewURL = previewURL == nil ? (selectedPreviewURL ?? items[0].url) : nil }
        else if key.key == .return {
            if let item = items.first(where: { $0.url == cursor }) ?? selection.first { model.openLibraryItem(item) }
        } else {
            let offset = key.key == .leftArrow ? -1 : key.key == .rightArrow ? 1 : key.key == .upArrow ? -columnCount : columnCount
            let index = cursor.flatMap { url in items.firstIndex { $0.url == url } }
            let next = index.map { ($0 + offset).clamped(to: 0...(items.count - 1)) } ?? 0
            select(items[next].url, extending: key.modifiers.contains(.shift))
        }
        return .handled
    }

    private func highlight(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        if let range = text.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = .yellow.opacity(0.35)
            text[range].font = .caption.bold()
        }
        return text
    }
}

private struct LibraryQuickLook: View {
    let url: URL
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    var body: some View {
        VStack {
            HStack {
                Text(url.lastPathComponent).lineLimit(1)
                Spacer()
                Button(action: previous) { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).help("Previous image")
                Button(action: next) { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).help("Next image")
                Button("Done", action: close).keyboardShortcut(.space, modifiers: [])
            }
            NativeQuickLook(url: url)
        }.padding().frame(width: 800, height: 560)
            .onExitCommand(perform: close)
    }
}

private struct NativeQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
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
            Text(StorageService.format(Int64(item.byteCount))).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}
