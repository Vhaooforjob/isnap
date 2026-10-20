import SwiftUI

struct WorkflowsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var workflows: [CaptureWorkflow] = []
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture Workflows").font(.title2.bold())
                Spacer()
                Button("Add") { let value = CaptureWorkflow(); workflows.append(value); selected = value.id }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top) {
                List(selection: $selected) {
                    ForEach(workflows) { Text($0.name).tag($0.id) }
                }.frame(width: 180)
                if let index = workflows.firstIndex(where: { $0.id == selected }) {
                    Form {
                        TextField("Name", text: $workflows[index].name)
                        TextField("Shortcut", text: $workflows[index].shortcut)
                        Text("Use modifier symbols, for example ⌃⌥9.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Capture region", isOn: $workflows[index].region)
                        Picker("Canvas preset", selection: $workflows[index].presetID) {
                            Text("No preset").tag(Optional<UUID>.none)
                            ForEach(model.features.state.presets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("Watermark text (optional)", text: $workflows[index].watermark)
                        Toggle("Save to Library", isOn: $workflows[index].saves)
                        Toggle("Copy image", isOn: $workflows[index].copies)
                        if FeatureAvailability.cloud {
                            Picker("Upload after capture", selection: $workflows[index].uploadProvider) {
                                Text("Off").tag(Optional<AppModel.CloudProvider>.none)
                                Text("Cloudflare R2").tag(Optional(AppModel.CloudProvider.r2))
                                Text("Google Drive").tag(Optional(AppModel.CloudProvider.googleDrive))
                                Text("DocVault").tag(Optional(AppModel.CloudProvider.docVault))
                            }
                            Text("An enabled upload sends each workflow capture to the selected connected provider and copies its link.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Remove", role: .destructive) { workflows.remove(at: index); selected = workflows.first?.id }
                            Spacer()
                            Button("Save Workflow") { model.features.state.workflows = workflows }
                                .disabled(!CaptureWorkflow.isValid(workflows))
                        }
                    }
                } else { Text("Add a workflow to capture, style, save and copy with one shortcut.").foregroundStyle(.secondary) }
            }
            if !model.workflowShortcutErrors.isEmpty {
                Text("Shortcuts unavailable: \(model.workflowShortcutErrors.joined(separator: ", "))").foregroundStyle(.red).font(.caption)
            }
            Text("Changes take effect after Save Workflow. Removing a workflow also requires saving.")
                .font(.caption).foregroundStyle(.secondary)
            if !CaptureWorkflow.isValid(workflows) {
                Text("Use a name and a unique shortcut with at least one modifier.").font(.caption).foregroundStyle(.red)
            }
            Button("Save All") { model.features.state.workflows = workflows }
                .disabled(!CaptureWorkflow.isValid(workflows))
        }.padding(20).frame(width: 750, height: 530).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { workflows = model.features.state.workflows ?? []; selected = workflows.first?.id }
    }
}
