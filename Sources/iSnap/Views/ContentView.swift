import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            CaptureToolbar()
            QuickAccessBar()
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
        .task { await model.reloadLibrary() }
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

private struct QuickAccessBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(recentItemLimit: 4, showsNames: true)
                .fixedSize(horizontal: true, vertical: false)
            content(recentItemLimit: 4, showsNames: false)
            content(recentItemLimit: 2, showsNames: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func content(recentItemLimit: Int, showsNames: Bool) -> some View {
        HStack(spacing: 8) {
            sectionButton(.editor)
            sectionButton(.library)
            Divider().frame(height: 24)
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.libraryItems.isEmpty {
                Text("No saved screenshots")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(model.libraryItems.prefix(recentItemLimit))) { item in
                    RecentLibraryItem(item: item, showsName: showsNames)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionButton(_ section: AppModel.Section) -> some View {
        Button {
            model.section = section
        } label: {
            Label(
                section == .library ? "Library \(model.libraryItems.count)" : section.rawValue,
                systemImage: section.symbol
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.section == section ? .accentColor : nil)
        .help("Open \(section.rawValue)")
    }
}

private struct RecentLibraryItem: View {
    @EnvironmentObject private var model: AppModel
    let item: LibraryItem
    let showsName: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.openLibraryItem(item)
            } label: {
                HStack(spacing: 6) {
                    thumbnail
                    if showsName {
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 96, alignment: .leading)
                    }
                }
                .padding(3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(item.name) in Editor")

            Button(role: .destructive) {
                Task { await model.deleteLibraryItem(item) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Move \(item.name) to Trash")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var thumbnail: some View {
        Group {
            if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 24)
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
