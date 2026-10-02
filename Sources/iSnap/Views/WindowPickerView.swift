import SwiftUI

struct WindowPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var windows: [CapturableWindow] {
        guard !search.isEmpty else { return model.availableWindows }
        return model.availableWindows.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.applicationName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(windows) { window in
                Button {
                    Task { await model.capture(window: window) }
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let thumbnail = window.thumbnail {
                                Image(nsImage: thumbnail).resizable().scaledToFit()
                            } else {
                                Image(systemName: "macwindow").font(.title2)
                            }
                        }
                        .frame(width: 88, height: 58)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.title).lineLimit(1)
                            Text("\(window.applicationName) • \(Int(window.frame.width)) × \(Int(window.frame.height))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search)
            .navigationTitle("Choose a Window")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 620, minHeight: 500)
    }
}
