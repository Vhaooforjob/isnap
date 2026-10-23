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
                .help(mode.help)
            }
            Menu {
                Menu("Workflows") {
                    ForEach(model.features.state.workflows ?? []) { workflow in
                        Button(workflow.name) { model.runWorkflow(workflow) }.disabled(model.isCapturing)
                    }
                    Divider()
                    Button("Manage Workflows…") { model.isShowingWorkflows = true }
                }
                Button("Capture Last Region") { Task { await model.captureLastRegion() } }
                    .disabled(model.lastRegion == nil || model.isCapturing)
                Button("Scrolling Capture…") { Task { await model.beginScrollingCapture() } }
                    .disabled(model.isCapturing)
                Divider()
                Picker("Capture delay", selection: Binding(get: { model.features.state.captureDelay }, set: { model.features.state.captureDelay = $0 })) {
                    Text("No delay").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Include cursor", isOn: Binding(get: { model.features.state.showsCursor }, set: { model.features.state.showsCursor = $0 }))
            } label: { Image(systemName: "timer") }
            .help("Capture options")
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
            Menu {
                Button("Save Project…", action: model.saveProject).disabled(model.document.image == nil)
                Button("Open Project…", action: model.openProject)
                if FeatureAvailability.cloud {
                    Button("Upload History…") { model.isShowingUploadHistory = true }
                }
                Button("Search Commands…") { model.isShowingCommands = true }
                Button("Find Duplicate Files…") { model.isShowingDuplicates = true }
                Button("Step Guide…", action: model.showGuide)
                Button("Combine Images / PDF…") { model.compositionPages = []; model.isShowingComposition = true }
                Menu("Recent Drafts") {
                    Button("Manage Drafts…") { model.isShowingDrafts = true }
                    Divider()
                    ForEach(Array(model.drafts.prefix(20)), id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.openProject(at: url) }
                    }
                    Divider()
                    Button("Show Drafts in Finder") { NSWorkspace.shared.open(ProjectStore.directory) }
                }
                Divider()
                Button("Pin on Screen", action: model.pinEditedImage).disabled(model.document.image == nil)
                Button("Suggest Redactions…") { Task { await model.findSensitiveInformation() } }
                    .disabled(model.document.image == nil || model.isParsingScreenshot)
            } label: { Image(systemName: "ellipsis.circle") }
            .help("Projects and image actions")
            Spacer()
            if model.isCapturing || model.isParsingScreenshot { ProgressView().controlSize(.small) }
            Button(action: model.showSettings) { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
