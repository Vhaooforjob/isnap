import SwiftUI

struct RedactionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Suggested Redactions").font(.title2.bold())
            Text("Select the lines to cover with solid black. Suggestions look for email addresses and phone numbers; review the image for anything else to hide.")
                .foregroundStyle(.secondary)
            if model.sensitiveRegions.isEmpty {
                ContentUnavailableView("No Suggestions", systemImage: "checkmark.shield",
                    description: Text("Use the Redact tool to cover information manually."))
            } else {
                List(model.sensitiveRegions) { region in
                    Toggle(region.text, isOn: Binding(get: { selected.contains(region.id) },
                        set: { if $0 { selected.insert(region.id) } else { selected.remove(region.id) } }))
                }
            }
            HStack {
                Button("Select All") { selected = Set(model.sensitiveRegions.map(\.id)) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Redactions") { model.redactRegions(selected) }.disabled(selected.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 440)
    }
}
