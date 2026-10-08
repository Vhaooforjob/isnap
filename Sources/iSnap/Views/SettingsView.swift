import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.hotkeys
    @State private var r2AccessKey = ""
    @State private var r2SecretKey = ""
    @State private var googleClientID = ""
    @State private var googleClientSecret = ""

    enum Tab: String, CaseIterable, Identifiable {
        case hotkeys = "Hotkeys"
        case startup = "Startup"
        case quickSave = "Quick Save"
        case captureLine = "Capture Line"
        case export = "Export"
        case updates = "Updates"
        case cloud = "Cloud"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .hotkeys: "keyboard"
            case .startup: "power"
            case .quickSave: "square.and.arrow.down"
            case .captureLine: "rectangle.3.group"
            case .export: "photo"
            case .updates: "arrow.triangle.2.circlepath"
            case .cloud: "cloud"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Tab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .frame(width: 170)
            VStack(spacing: 0) {
                Form {
                    switch tab {
                    case .hotkeys: hotkeys
                    case .startup: startup
                    case .quickSave: quickSave
                    case .captureLine: captureLine
                    case .export: export
                    case .updates: updates
                    case .cloud: cloud
                    }
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Text("Settings are saved automatically.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 700, minHeight: 510)
        .onAppear {
            store.value.startup.launchAtLogin = LaunchAtLoginService.isEnabled
            r2AccessKey = KeychainStore.shared.value(for: .r2AccessKeyID) ?? ""
            r2SecretKey = KeychainStore.shared.value(for: .r2SecretAccessKey) ?? ""
            googleClientID = KeychainStore.shared.value(for: .googleClientID) ?? ""
            googleClientSecret = KeychainStore.shared.value(for: .googleClientSecret) ?? ""
        }
        .task(id: tab) {
            guard tab == .cloud else { return }
            while !Task.isCancelled {
                if model.docVaultConnected {
                    await model.refreshDocVault(showError: false)
                }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private var hotkeys: some View {
        Group {
            Section("Global capture shortcuts") {
                LabeledContent("All displays") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.fullScreen))
                }
                LabeledContent("Region") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.region))
                }
                LabeledContent("Window") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.window))
                }
                LabeledContent("Show or hide Capture Line") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.toggleCaptureLine))
                }
            }
            Section("Editor shortcuts") {
                LabeledContent("Save edited image") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.saveEditedImage))
                }
                LabeledContent("Copy edited image") {
                    HotkeyRecorder(shortcut: setting(\.hotkeys.copyEditedImage))
                }
            }
            Text("Click a shortcut, then press a modifier combination and a letter, number, or F1–F12. Editor shortcuts work while iSnap is active. Press Escape to cancel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var startup: some View {
        Section("Application behavior") {
            Toggle("Launch iSnap at login", isOn: Binding(
                get: { store.value.startup.launchAtLogin },
                set: { enabled in
                    do {
                        try LaunchAtLoginService.setEnabled(enabled)
                        store.value.startup.launchAtLogin = enabled
                    } catch { model.errorMessage = error.localizedDescription }
                }
            ))
            Toggle("Start hidden", isOn: setting(\.startup.startHidden))
            Toggle("Close to menu bar", isOn: setting(\.startup.closeToMenuBar))
            Toggle("Play sound after save", isOn: setting(\.startup.showNotifications))
            Text("Launch at login works after iSnap.app is placed in Applications. macOS may require approval in System Settings → General → Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var captureLine: some View {
        Group {
            Section("Capture Line") {
                Toggle("Hang new captures on a line under the menu bar", isOn: setting(\.captureLine.isEnabled))
                Toggle("Open the editor after each capture", isOn: setting(\.captureLine.opensEditorAfterCapture))
                    .disabled(!store.value.captureLine.isEnabled)
                Toggle("Reveal the line when the pointer rests in the menu bar", isOn: setting(\.captureLine.revealsFromMenuBar))
                    .disabled(!store.value.captureLine.isEnabled)
                Toggle("Play sounds", isOn: setting(\.captureLine.playsSounds))
                    .disabled(!store.value.captureLine.isEnabled)
            }
            Section("macOS screenshots") {
                Toggle("Also hang screenshots taken with ⇧⌘3, ⇧⌘4 and ⇧⌘5", isOn: setting(\.captureLine.hangsSystemScreenshots))
                    .disabled(!store.value.captureLine.isEnabled)
                Toggle("Keep them off the Desktop", isOn: setting(\.captureLine.routesSystemScreenshots))
                    .disabled(!store.value.captureLine.isEnabled || !store.value.captureLine.hangsSystemScreenshots)
                Text("Turns off the floating thumbnail and saves new macOS screenshots to iSnap's line folder, the same options found in ⇧⌘5. Drag one to a folder to keep it. Your previous settings come back when this is turned off or iSnap quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Gestures") {
                Text("Click copies • Double-click edits in iSnap • Press and hold opens Markup • Drag into an app sends a copy • Drag to the Trash or click the cross takes it down • Right-click for more.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Captures that only live on the line are trashed when taken down. Library files are never deleted from the line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quickSave: some View {
        Section("Destination") {
            LabeledContent("Folder") { Text(store.value.quickSave.folder.path).lineLimit(1).truncationMode(.middle) }
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { store.value.quickSave.folder = url }
            }
            Picker("Filename", selection: setting(\.quickSave.pattern)) {
                ForEach(FilenamePattern.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Automatically save every capture to Library", isOn: setting(\.quickSave.autoSaveCaptures))
        }
    }

    private var export: some View {
        Section("Defaults") {
            Picker("Format", selection: setting(\.export.defaultFormat)) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            if store.value.export.defaultFormat == .jpeg {
                LabeledContent("JPEG quality") {
                    Slider(value: setting(\.export.jpegQuality), in: 0.5...1).frame(width: 220)
                    Text("\(Int(store.value.export.jpegQuality * 100))%")
                }
            }
            Toggle("Include canvas background", isOn: setting(\.export.includeBackground))
            Toggle("Copy to clipboard after quick save", isOn: setting(\.export.autoCopyToClipboard))
        }
    }

    private var updates: some View {
        Section("Software updates") {
            Toggle("Check automatically on launch", isOn: setting(\.update.checkOnStartup))
            Button("Check Now") { Task { await model.checkForUpdates() } }
            Text("Current version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                .foregroundStyle(.secondary)
        }
    }

    private var cloud: some View {
        Group {
            Section("DocVault") {
                TextField("API server", text: setting(\.cloud.docVault.serverURL))
                    .disabled(model.docVaultConnected)
                TextField("Web app", text: setting(\.cloud.docVault.webURL))
                if model.docVaultConnected {
                    LabeledContent("Signed in") {
                        Text(model.docVaultUser?.email ?? "Connected")
                            .foregroundStyle(.secondary)
                    }
                    if !model.docVaultWorkspaces.isEmpty {
                        Picker("Upload workspace", selection: setting(\.cloud.docVault.workspaceID)) {
                            ForEach(model.docVaultWorkspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }
                    } else {
                        Text("Create a workspace in DocVault before uploading screenshots.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.docVaultAccounts.count > 1 {
                        Picker("Google Drive account", selection: Binding(
                            get: { model.defaultDocVaultAccount?.id ?? "" },
                            set: { accountID in Task { await model.selectDocVaultStorageAccount(accountID) } }
                        )) {
                            ForEach(model.docVaultAccounts) { account in
                                Text(account.email).tag(account.id)
                            }
                        }
                    }
                    if let account = model.defaultDocVaultAccount {
                        docVaultQuota(account)
                    } else {
                        Text("No active Google Drive storage account is linked in DocVault.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Circle().fill(model.docVaultConnected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(model.docVaultConnected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                    Spacer()
                    if model.docVaultConnected {
                        Button("Refresh") { Task { await model.refreshDocVault() } }
                            .disabled(model.isRefreshingDocVault)
                        Button("Disconnect") { Task { await model.disconnectDocVault() } }
                    } else {
                        Button("Connect") { Task { await model.connectDocVault() } }
                            .disabled(model.isRefreshingDocVault || store.value.cloud.docVault.serverURL.isEmpty)
                    }
                }
                Text("iSnap uploads through DocVault. Google credentials remain in DocVault; only the DocVault session is stored in macOS Keychain. Capacity refreshes after uploads and every minute while this page is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cloudflare R2") {
                TextField("Account ID", text: setting(\.cloud.r2.accountID))
                SecureField("Access Key ID", text: $r2AccessKey)
                SecureField("Secret Access Key", text: $r2SecretKey)
                TextField("Bucket", text: setting(\.cloud.r2.bucket))
                TextField("Public URL", text: setting(\.cloud.r2.publicURL))
                TextField("Directory", text: setting(\.cloud.r2.directory))
                HStack {
                    Circle().fill(model.r2Connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(model.r2Connected ? "Connected" : "Not tested").foregroundStyle(.secondary)
                    Spacer()
                    Button("Save & Test") { Task { await model.configureR2(accessKeyID: r2AccessKey, secretAccessKey: r2SecretKey) } }
                        .disabled(r2AccessKey.isEmpty || r2SecretKey.isEmpty)
                }
            }
            Section("Google Drive") {
                TextField("OAuth Client ID", text: $googleClientID)
                SecureField("OAuth Client Secret", text: $googleClientSecret)
                TextField("Folder ID (optional)", text: setting(\.cloud.googleDrive.folderID))
                HStack {
                    Circle().fill(model.googleDriveConnected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(model.googleDriveConnected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                    Spacer()
                    if model.googleDriveConnected {
                        Button("Disconnect") { Task { await model.disconnectGoogleDrive() } }
                    } else {
                        Button("Connect") { Task { await model.connectGoogleDrive(clientID: googleClientID, clientSecret: googleClientSecret) } }
                            .disabled(googleClientID.isEmpty || googleClientSecret.isEmpty)
                    }
                }
                Text("Create a Desktop OAuth client whose loopback redirect can use http://127.0.0.1:8089/callback. Secrets and tokens are stored in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func docVaultQuota(_ account: DocVaultStorageAccount) -> some View {
        LabeledContent("Google Drive") {
            VStack(alignment: .trailing, spacing: 4) {
                Text(account.email)
                if let remaining = account.remainingBytes, let total = account.quotaBytes,
                   let used = account.quotaUsedBytes, total > 0 {
                    ProgressView(value: Double(min(used, total)), total: Double(total))
                        .frame(width: 220)
                    Text("\(Self.byteFormatter.string(fromByteCount: remaining)) free of \(Self.byteFormatter.string(fromByteCount: total))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Capacity unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let value = ByteCountFormatter()
        value.countStyle = .file
        value.allowedUnits = [.useMB, .useGB, .useTB]
        value.includesUnit = true
        return value
    }()

    private func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { store.value[keyPath: keyPath] = $0 }
        )
    }
}
