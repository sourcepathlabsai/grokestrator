import SwiftUI
import GrokestratorCore

/// Create or edit a custom ACP harness team template — agent, roles, personas,
/// and grok-assisted prompt drafting. Custom templates write `.grok/` files at use time.
struct HarnessTemplateEditorView: View {
    @Bindable var model: GrokestratorModel
    let existingID: String?
    @Environment(\.dismiss) private var dismiss

    @State private var template: GrokHarnessTemplate
    @State private var drafting: DraftTarget?
    @State private var isDraftingAll = false
    @State private var errorMessage: String?

    private enum DraftTarget: Equatable {
        case agent, role(Int), persona(Int)
    }

    private static let capabilityModes = ["default", "read-only", "read-write", "execute", "all"]

    init(model: GrokestratorModel, existing: GrokHarnessTemplate? = nil) {
        self.model = model
        self.existingID = existing?.id
        _template = State(initialValue: existing ?? .blank())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existingID == nil ? "New Harness Template" : "Edit Harness Template")
                .font(.headline)
                .padding()
            Divider()

            Form {
                Section {
                    TextField("Title", text: $template.title)
                    TextField("Summary", text: $template.summary, axis: .vertical)
                        .lineLimit(2...4)
                    if existingID == nil {
                        LabeledContent("ID") {
                            Text(template.id)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Template").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextField("Agent name", text: $template.agent.name)
                        .font(.system(.body, design: .monospaced))
                    TextField("Description", text: $template.agent.description, axis: .vertical)
                        .lineLimit(2...3)
                    TextField("Model", text: $template.agent.model)
                        .font(.system(.body, design: .monospaced))
                    draftRow(label: "System prompt", target: .agent) {
                        TextEditor(text: $template.agent.systemPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                } header: {
                    Text("Primary agent (`.grok/agents/`)").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(Array(template.roles.enumerated()), id: \.element.id) { index, _ in
                        roleSection(index: index)
                    }
                    Button {
                        template.roles.append(
                            .init(name: "role\(template.roles.count + 1)",
                                  description: "Describe this harness role.",
                                  capabilityMode: "read-only", prompt: "")
                        )
                    } label: {
                        Label("Add role", systemImage: "plus")
                    }
                } header: {
                    HStack {
                        Text("Roles (`.grok/roles/`)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await draftAllRoles() } } label: {
                            Label("Draft all roles", systemImage: "sparkles")
                        }
                        .disabled(isDraftingAll || drafting != nil)
                    }
                }

                Section {
                    ForEach(Array(template.personas.enumerated()), id: \.element.id) { index, _ in
                        personaSection(index: index)
                    }
                    Button {
                        template.personas.append(
                            .init(name: "persona\(template.personas.count + 1)",
                                  description: "Behavioral tuning for a subagent type.")
                        )
                    } label: {
                        Label("Add persona", systemImage: "plus")
                    }
                } header: {
                    Text("Personas (`.grok/personas/`) — optional").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 640)
        .frame(minHeight: 560)
        .onChange(of: template.title) { _, new in
            guard existingID == nil else { return }
            let slug = GrokHarnessTemplate.slug(from: new)
            if !slug.isEmpty, !GrokHarnessTemplate.builtinIDs.contains(slug) {
                template = GrokHarnessTemplate(
                    id: slug, title: template.title, summary: template.summary,
                    agent: template.agent, roles: template.roles, personas: template.personas
                )
            }
        }
    }

    @ViewBuilder
    private func draftRow<Content: View>(label: String, target: DraftTarget, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await draft(target) } } label: {
                    Label("Draft with grok", systemImage: "sparkles")
                }
                .disabled(drafting != nil || isDraftingAll)
            }
            content()
                .opacity(drafting == target ? 0.5 : 1)
                .overlay {
                    if drafting == target { ProgressView("Drafting…").controlSize(.small) }
                }
        }
    }

    private func roleSection(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Role \(index + 1)").font(.caption.weight(.semibold))
                Spacer()
                Button(role: .destructive) { template.roles.remove(at: index) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Name", text: roleBinding(index, \.name))
                .font(.system(.body, design: .monospaced))
            TextField("Description", text: roleBinding(index, \.description), axis: .vertical)
                .lineLimit(2...3)
            Picker("Capability", selection: roleBinding(index, \.capabilityMode)) {
                ForEach(Self.capabilityModes, id: \.self) { m in Text(m).tag(m) }
            }
            draftRow(label: "Role prompt", target: .role(index)) {
                TextEditor(text: roleBinding(index, \.prompt))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
        .padding(.vertical, 4)
    }

    private func personaSection(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Persona \(index + 1)").font(.caption.weight(.semibold))
                Spacer()
                Button(role: .destructive) { template.personas.remove(at: index) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Name", text: personaBinding(index, \.name))
                .font(.system(.body, design: .monospaced))
            TextField("Description", text: personaBinding(index, \.description), axis: .vertical)
                .lineLimit(2...2)
            draftRow(label: "Instructions", target: .persona(index)) {
                TextEditor(text: personaBinding(index, \.instructions))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
        .padding(.vertical, 4)
    }

    private func roleBinding(_ index: Int, _ keyPath: WritableKeyPath<GrokRoleDraft, String>) -> Binding<String> {
        Binding(
            get: { template.roles[index][keyPath: keyPath] },
            set: { template.roles[index][keyPath: keyPath] = $0 }
        )
    }

    private func personaBinding(_ index: Int, _ keyPath: WritableKeyPath<GrokPersonaDraft, String>) -> Binding<String> {
        Binding(
            get: { template.personas[index][keyPath: keyPath] },
            set: { template.personas[index][keyPath: keyPath] = $0 }
        )
    }

    private var canSave: Bool {
        !template.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !template.agent.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !template.isBuiltin
            && idIsUnique
    }

    private var idIsUnique: Bool {
        let others = model.customHarnessTemplates.filter { $0.id != existingID }
        return !others.contains(where: { $0.id == template.id })
            && !GrokHarnessTemplate.builtinIDs.contains(template.id)
    }

    private func save() {
        guard canSave else {
            errorMessage = "Fix title, agent name, or duplicate ID before saving."
            return
        }
        model.saveCustomHarnessTemplate(template)
        dismiss()
    }

    private func draft(_ target: DraftTarget) async {
        drafting = target
        defer { drafting = nil }
        switch target {
        case .agent:
            let text = await model.draftHarnessAgentPrompt(template: template)
            if !text.isEmpty { template.agent.systemPrompt = text }
        case .role(let i):
            let text = await model.draftHarnessRolePrompt(template: template, roleIndex: i)
            if !text.isEmpty { template.roles[i].prompt = text }
        case .persona(let i):
            let text = await model.draftHarnessPersonaInstructions(template: template, personaIndex: i)
            if !text.isEmpty { template.personas[i].instructions = text }
        }
    }

    private func draftAllRoles() async {
        isDraftingAll = true
        let agentText = await model.draftHarnessAgentPrompt(template: template)
        if !agentText.isEmpty { template.agent.systemPrompt = agentText }
        for i in template.roles.indices {
            drafting = .role(i)
            let text = await model.draftHarnessRolePrompt(template: template, roleIndex: i)
            if !text.isEmpty { template.roles[i].prompt = text }
        }
        drafting = nil
        isDraftingAll = false
    }
}