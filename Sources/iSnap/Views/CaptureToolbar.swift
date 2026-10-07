import SwiftUI

struct CaptureToolbar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    Task { await model.capture(mode) }
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                }
                .disabled(model.isCapturing)
                .help("Capture \(mode.title.lowercased())")
            }
            Divider().frame(height: 20)
            Button(action: model.openImage) { Label("Open", systemImage: "folder") }
            Button(action: model.pasteImage) { Label("Paste", systemImage: "doc.on.clipboard") }
            Divider().frame(height: 20)
            Button {
                Task { await model.parseScreenshot() }
            } label: {
                Label("Extract Text", systemImage: "text.viewfinder")
            }
            .disabled(model.document.image == nil || model.isParsingScreenshot)
            .help("Extract text from the current screenshot using macOS Vision")
            Spacer()
            if model.isCapturing || model.isParsingScreenshot { ProgressView().controlSize(.small) }
            Button { model.isShowingSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
