import SwiftUI

struct RedactionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var showingRules = false
    @State private var wholeLines = true
    @State private var generation = 0
    @State private var busy = false
    @State private var error: String?

    private func regionOverlay(_ region: RecognizedRegion, scale: CGFloat) -> some View {
        let fill: Color = selected.contains(region.id) ? .black : Color.orange.opacity(0.25)
        let width: CGFloat = max(2, (region.rect.width + 8) * scale)
        let height: CGFloat = max(2, (region.rect.height + 8) * scale)
        let x: CGFloat = (region.rect.minX - 4) * scale
        let y: CGFloat = (region.rect.minY - 4) * scale
        return Rectangle().fill(fill)
            .overlay(Rectangle().stroke(.orange, lineWidth: 1))
            .frame(width: width, height: height)
            .offset(x: x, y: y)
            .onTapGesture { toggle(region.id) }
            .accessibilityLabel(region.text).accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle(region.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Suggested Redactions").font(.title2.bold())
            HStack {
                Toggle("Cover entire matching lines", isOn: $wholeLines)
                Button("Redaction Rules…") { showingRules = true }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            HStack {
                GeometryReader { geometry in
                    if let image = model.redactionSource {
                        let sourceSize = model.document.imagePixelSize
                        let scale = min(geometry.size.width / max(1, sourceSize.width), geometry.size.height / max(1, sourceSize.height))
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image).resizable().frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
                            ForEach(model.sensitiveRegions) { region in
                                regionOverlay(region, scale: scale)
                            }
                        }
                    }
                }.frame(minWidth: 400)
                List(model.sensitiveRegions) { region in
                    VStack(alignment: .leading) {
                        Toggle(region.text, isOn: Binding(get: { selected.contains(region.id) }, set: { _ in toggle(region.id) }))
                        Text(model.redactionMatches.first(where: { $0.id == region.id })?.reason ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 290)
            }.disabled(busy)
            Text("Orange regions are suggestions. Selected regions preview the solid mask; review the rest of the image before applying.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Select All") { selected = Set(model.sensitiveRegions.map(\.id)) }.disabled(busy)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Redactions") { model.redactRegions(selected) }.disabled(selected.isEmpty || busy || error != nil)
            }
        }.padding(20).frame(width: 840, height: 560)
        .sheet(isPresented: $showingRules, onDismiss: { generation += 1 }) { RedactionRulesView().environmentObject(model) }
        .onChange(of: wholeLines) { _, _ in generation += 1 }
        .task(id: generation) {
            busy = true; error = nil; selected = []
            do {
                let matches = try await RedactionMatcher().match(model.redactionRegions, rules: model.features.state.redactionRules ?? [], wholeLines: wholeLines)
                try Task.checkCancellation()
                model.redactionMatches = matches; model.sensitiveRegions = matches.map(\.region); busy = false
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; busy = false; model.sensitiveRegions = [] }
        }
    }
    private func toggle(_ id: UUID) { if !selected.insert(id).inserted { selected.remove(id) } }
}

struct RedactionRulesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pattern = ""
    @State private var regex = false
    @State private var editingID: UUID?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Redaction Rules").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Name rules by project. Enabled rules suggest matching text. Choose entire lines or matched phrases in the review; inspect every suggestion before applying it.")
                .font(.caption).foregroundStyle(.secondary)
            List(model.features.state.redactionRules ?? []) { rule in
                HStack {
                    Toggle(rule.name, isOn: Binding(get: {
                        model.features.state.redactionRules?.first(where: { $0.id == rule.id })?.enabled ?? false
                    }, set: { enabled in
                        if let index = model.features.state.redactionRules?.firstIndex(where: { $0.id == rule.id }) {
                            model.features.state.redactionRules?[index].enabled = enabled
                        }
                    }))
                    Spacer()
                    Text(rule.pattern).font(.caption.monospaced()).lineLimit(1)
                    Button("Edit") { editingID = rule.id; name = rule.name; pattern = rule.pattern; regex = rule.regularExpression; error = nil }
                    Button("Delete", role: .destructive) {
                        model.features.state.redactionRules?.removeAll { $0.id == rule.id }
                        if editingID == rule.id { reset() }
                    }
                }
            }
            TextField("Rule name", text: $name)
            TextField("Keyword or regular expression", text: $pattern)
            Toggle("Regular expression (case insensitive)", isOn: $regex)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Clear", action: reset)
                Spacer()
                Button(editingID == nil ? "Add Rule" : "Save Rule", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pattern.isEmpty)
            }
        }.padding(20).frame(width: 640, height: 460)
    }
    private func reset() { editingID = nil; name = ""; pattern = ""; regex = false; error = nil }
    private func save() {
        var rule = RedactionRule(name: name.trimmingCharacters(in: .whitespacesAndNewlines), pattern: pattern, regularExpression: regex)
        do { _ = try rule.expression() }
        catch { self.error = error.localizedDescription; return }
        var rules = model.features.state.redactionRules ?? []
        if let editingID, let index = rules.firstIndex(where: { $0.id == editingID }) {
            rule.id = editingID; rule.enabled = rules[index].enabled; rules[index] = rule
        } else { rules.append(rule) }
        model.features.state.redactionRules = rules
        reset()
    }
}
