import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private var results: [WorkspaceCommand] { WorkspaceCommand.search(model.workspaceCommands, query: query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search commands…", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { executeSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { command in
                            Button { execute(command) } label: {
                                HStack {
                                    Image(systemName: command.symbol).frame(width: 24)
                                    Text(command.title)
                                    Spacer()
                                    Text(command.category).font(.caption).foregroundStyle(.secondary)
                                }.padding(9).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!command.enabled)
                                .background(selection == command.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .id(command.id)
                        }
                        if results.isEmpty { Text("No matching commands").foregroundStyle(.secondary).padding() }
                    }
                }.onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Text("↑ ↓ to choose · Return to run · Escape to close").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 560, height: 420)
        .onAppear { focused = true; selection = results.first(where: \.enabled)?.id }
        .onChange(of: query) { _, _ in selection = results.first(where: \.enabled)?.id }
    }
    private func move(_ delta: Int) {
        let available = results.filter(\.enabled)
        guard !available.isEmpty else { selection = nil; return }
        let current = available.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : available.count)
        selection = available[(current + delta).clamped(to: 0...(available.count - 1))].id
    }
    private func executeSelected() {
        if let command = results.first(where: { $0.id == selection && $0.enabled }) { execute(command) }
    }
    private func execute(_ command: WorkspaceCommand) {
        guard command.enabled else { return }
        model.pendingCommand = command.perform
        dismiss()
    }
}
