import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: LibraryItem.ID?
    @State private var isConfirmingDeleteAll = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Screenshot Library").font(.title2.bold())
                Text("\(model.libraryItems.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder", systemImage: "folder") { model.revealLibrary() }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.reloadLibrary() } }
                Button("Move All to Trash", systemImage: "trash", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
                .disabled(model.libraryItems.isEmpty)
            }
            .padding()
            Divider()
            if model.libraryItems.isEmpty {
                ContentUnavailableView(
                    "No Screenshots Yet",
                    systemImage: "photo.stack",
                    description: Text("Quick-saved screenshots will appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.libraryItems) { item in
                            LibraryCard(item: item, isSelected: selected == item.id)
                                .onTapGesture { selected = item.id }
                                .onTapGesture(count: 2) { model.openLibraryItem(item) }
                                .contextMenu {
                                    Button("Open in Editor") { model.openLibraryItem(item) }
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { Task { await model.deleteLibraryItem(item) } }
                                }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task { await model.reloadLibrary() }
        .onDeleteCommand {
            guard let selected, let item = model.libraryItems.first(where: { $0.id == selected }) else { return }
            Task { await model.deleteLibraryItem(item) }
        }
        .confirmationDialog(
            "Move all screenshots to Trash?",
            isPresented: $isConfirmingDeleteAll
        ) {
            Button("Move \(model.libraryItems.count) Screenshots to Trash", role: .destructive) {
                selected = nil
                Task { await model.deleteAllLibraryItems() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every screenshot currently shown in the Library. You can recover them from the Trash.")
        }
    }
}

private struct LibraryCard: View {
    let item: LibraryItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = NSImage(contentsOf: item.url) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                }
            }
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
