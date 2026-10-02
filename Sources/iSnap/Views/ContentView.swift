import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            CaptureToolbar()
            Picker("Section", selection: $model.section) {
                ForEach(AppModel.Section.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.vertical, 7)
            if model.section == .editor {
                AnnotationToolbar(document: model.document)
                HSplitView {
                    EditorCanvasHost(document: model.document)
                        .frame(minWidth: 560, minHeight: 420)
                    CanvasSettingsPanel(document: model.document, settings: model.settings)
                }
            } else {
                LibraryView()
            }
            statusBar
        }
        .frame(minWidth: 940, minHeight: 680)
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(store: model.settings).environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingWindowPicker) {
            WindowPickerView().environmentObject(model)
        }
        .alert("iSnap", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .alert("Screen Recording Access", isPresented: $model.isShowingScreenRecordingRecovery) {
            Button("Restart iSnap") { model.restartApplication() }
            Button("Open System Settings") { model.openScreenRecordingSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS has not applied Screen Recording access to this running copy of iSnap. If the switch is already enabled, restart iSnap. Otherwise open System Settings and enable it first.")
        }
        .alert(item: $model.releaseInfo) { release in
            Alert(
                title: Text("iSnap \(release.tagName) is available"),
                message: Text(release.body ?? "A newer version is ready to download."),
                primaryButton: .default(Text("Open Download")) { NSWorkspace.shared.open(release.htmlURL) },
                secondaryButton: .cancel()
            )
        }
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(model.isCapturing ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(model.statusText)
            Spacer()
            if model.document.image != nil {
                Button("Copy", systemImage: "doc.on.doc", action: model.copy)
                Button("Quick Save", systemImage: "bolt", action: model.quickSave)
                Menu {
                    Button("Cloudflare R2") { Task { await model.upload(to: .r2) } }
                        .disabled(!model.r2Connected)
                    Button("Google Drive") { Task { await model.upload(to: .googleDrive) } }
                        .disabled(!model.googleDriveConnected)
                } label: {
                    Label(model.isUploading ? "Uploading…" : "Upload", systemImage: "icloud.and.arrow.up")
                }
                .disabled(model.isUploading || (!model.r2Connected && !model.googleDriveConnected))
                Button("Export…", systemImage: "square.and.arrow.up", action: model.saveAs)
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }
}
