import AppKit
import SwiftUI

struct ScreenshotParseView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let sourceName: String

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
        .frame(minWidth: 620, minHeight: 440)
    }
}
