import SwiftUI

struct UploadHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack {
                Text("Upload History").font(.title2.bold())
                Spacer()
                Button("Clear History") {
                    Task {
                        do {
                            try await Task.detached { try UploadHistoryStore.save([]) }.value
                            model.uploadHistory = []
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                }.disabled(model.isUploading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            List(model.uploadHistory) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.provider).font(.headline)
                        Text(entry.date, style: .date).font(.caption)
                        Text(entry.url.absoluteString).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
                    }
                    Link("Open", destination: entry.url)
                }
            }
            Text("Clearing history removes local links only. Uploaded files remain with the provider.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 680, height: 420).background(Color(nsColor: .windowBackgroundColor))
    }
}
