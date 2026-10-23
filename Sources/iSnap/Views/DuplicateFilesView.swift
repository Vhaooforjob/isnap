import SwiftUI

struct DuplicateFilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: DuplicateScanResult?
    @State private var selected: Set<URL> = []
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    @State private var run = UUID()
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Duplicate Files").font(.title2.bold())
                Spacer()
                Button("Scan Again", action: scan).disabled(busy)
                Button("Done") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Find identical file contents in the screenshot folder. Nothing is selected or deleted automatically. Files that only look alike may have different contents.")
                .font(.callout)
            if busy { HStack { ProgressView().controlSize(.small); Text(progress); Button("Cancel Scan") { task?.cancel() } } }
            if let result {
                Text("Duplicate groups: \(result.groups.count)").font(.headline)
                List {
                    ForEach(result.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                HStack {
                                    Toggle(item.name, isOn: Binding(get: { selected.contains(item.url) }, set: {
                                        if $0 { selected.insert(item.url) } else { selected.remove(item.url) }
                                    })).lineLimit(1)
                                    Spacer()
                                    LibraryThumbnail(item: item, maxPixelSize: 160).frame(width: 80, height: 50)
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                }
                            }
                        } header: { Text("Identical files: \(group.items.count)") }
                    }
                }
                if result.groups.isEmpty { Text("No identical files found.").foregroundStyle(.secondary) }
                if !result.skipped.isEmpty {
                    Text("Skipped unreadable or changed files: \(result.skipped.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else { Spacer() }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("Review selected files in Library before moving anything to Trash.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Review in Library") {
                    let selection = selected, id = run
                    busy = true; progress = String(localized: "Reading screenshot folder…")
                    task = Task {
                        defer { if run == id { busy = false } }
                        await model.reloadLibrary()
                        guard !Task.isCancelled, run == id else { return }
                        model.libraryReviewSelection = selection; model.section = .library; dismiss()
                    }
                }.disabled(selected.isEmpty || busy)
            }
        }.padding(20).frame(width: 740, height: 540)
        .onAppear(perform: scan)
        .onDisappear { run = UUID(); task?.cancel() }
        .onChange(of: model.settings.value.quickSave.folder) { _, _ in scan() }
    }
    private func scan() {
        task?.cancel(); let id = UUID(); run = id
        busy = true; result = nil; selected = []; error = nil; progress = String(localized: "Reading screenshot folder…")
        let folder = model.settings.value.quickSave.folder
        task = Task {
            defer { if run == id { busy = false } }
            do {
                let items = try await LibraryService().items(in: folder)
                try Task.checkCancellation()
                let scanned = try await DuplicateFileService().scan(items) { done, total in
                    Task { @MainActor in if run == id { progress = String(localized: "Checking files: \(done)/\(total)") } }
                }
                try Task.checkCancellation()
                guard run == id else { return }; result = scanned
            } catch is CancellationError { if run == id { progress = ""; error = String(localized: "Scan canceled. Run it again to see complete results.") } }
            catch { if run == id { self.error = error.localizedDescription } }
        }
    }
}
