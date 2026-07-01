import SwiftUI
import GrokestratorCore

/// Create or edit a custom fleet team template — members, plain descriptions,
/// role prompts, and grok-assisted prompt drafting.
struct TeamTemplateEditorView: View {
    @Bindable var model: GrokestratorModel
    /// `nil` ⇒ new template.
    let existingID: String?
    @Environment(\.dismiss) private var dismiss

    @State private var template: TeamTemplate
    @State private var draftingIndex: Int?
    @State private var isDraftingAll = false
    @State private var errorMessage: String?

    init(model: GrokestratorModel, existing: TeamTemplate? = nil) {
        self.model = model
        self.existingID = existing?.id
        _template = State(initialValue: existing ?? .blank())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existingID == nil ? "New Team Template" : "Edit Team Template")
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
                    ForEach(Array(template.members.enumerated()), id: \.element.id) { index, _ in
                        memberSection(index: index)
                    }
                    Button {
                        template.members.append(
                            .init(nameSuffix: "-member\(template.members.count)",
                                  displayName: "New Member",
                                  memberDescription: "Describe this member's job.",
                                  rolePrompt: "",
                                  autoApproval: .init(level: .reads))
                        )
                    } label: {
                        Label("Add member", systemImage: "plus")
                    }
                } header: {
                    HStack {
                        Text("Members").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await draftAll() }
                        } label: {
                            Label("Draft all prompts", systemImage: "sparkles")
                        }
                        .disabled(isDraftingAll || draftingIndex != nil)
                    }
                } footer: {
                    Text("First member is the orchestrator. Plain names and descriptions feed “Draft with grok”.")
                        .font(.caption2)
                }

                Section {
                    Text("Per-member design-oracle attachment — coming in a later slice.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("Oracles (future)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
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
        .frame(width: 620)
        .frame(minHeight: 520)
        .onChange(of: template.title) { _, new in
            guard existingID == nil else { return }
            let slug = TeamTemplate.slug(from: new)
            if !slug.isEmpty, !TeamTemplate.builtinIDs.contains(slug) {
                template = TeamTemplate(
                    id: slug,
                    title: template.title,
                    summary: template.summary,
                    members: template.members,
                    requiresOrchestratedFleet: template.requiresOrchestratedFleet
                )
            }
        }
    }

    @ViewBuilder
    private func memberSection(index: Int) -> some View {
        let isOrch = index == 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isOrch ? "point.3.connected.trianglepath.dotted" : "person.fill")
                    .foregroundStyle(isOrch ? .cyan : .secondary)
                Text(isOrch ? "Orchestrator" : "Member \(index)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !isOrch {
                    Button(role: .destructive) {
                        template.members.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove member")
                }
            }

            TextField("Display name", text: memberBinding(index, keyPath: \.displayName))
            TextField("Description (plain language)", text: memberBinding(index, keyPath: \.memberDescription), axis: .vertical)
                .lineLimit(2...3)

            if !isOrch {
                TextField("Name suffix", text: memberBinding(index, keyPath: \.nameSuffix),
                          prompt: Text("-reviewer"))
                    .font(.system(.body, design: .monospaced))
            }

            if !isOrch {
                Picker("Auto-approval", selection: memberApprovalBinding(index)) {
                    Text("Ask").tag(AutoApproval.Level.manual)
                    Text("Reads").tag(AutoApproval.Level.reads)
                    Text("+ Edits").tag(AutoApproval.Level.edits)
                    Text("All").tag(AutoApproval.Level.all)
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Text("Role prompt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await draftOne(index) }
                } label: {
                    Label("Draft with grok", systemImage: "sparkles")
                }
                .disabled(draftingIndex != nil || isDraftingAll)
            }

            TextEditor(text: memberBinding(index, keyPath: \.rolePrompt))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .opacity(draftingIndex == index ? 0.5 : 1)
                .overlay {
                    if draftingIndex == index {
                        ProgressView("Drafting…").controlSize(.small)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private func memberBinding(_ index: Int, keyPath: WritableKeyPath<TeamTemplate.Member, String>) -> Binding<String> {
        Binding(
            get: { template.members[index][keyPath: keyPath] },
            set: { template.members[index][keyPath: keyPath] = $0 }
        )
    }

    private func memberApprovalBinding(_ index: Int) -> Binding<AutoApproval.Level> {
        Binding(
            get: { template.members[index].autoApproval.level },
            set: { template.members[index].autoApproval = AutoApproval(level: $0) }
        )
    }

    private var canSave: Bool {
        !template.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !template.members.isEmpty
            && template.members[0].isOrchestrator
            && !template.isBuiltin
            && idIsUnique
    }

    private var idIsUnique: Bool {
        let others = model.customTeamTemplates.filter { $0.id != existingID }
        return !others.contains(where: { $0.id == template.id })
            && !TeamTemplate.builtinIDs.contains(template.id)
    }

    private func save() {
        guard canSave else {
            errorMessage = "Fix title, members, or duplicate ID before saving."
            return
        }
        model.saveCustomTeamTemplate(template)
        dismiss()
    }

    private func draftOne(_ index: Int) async {
        draftingIndex = index
        let drafted = await model.draftTemplateMemberPrompt(template: template, memberIndex: index)
        draftingIndex = nil
        if !drafted.isEmpty { template.members[index].rolePrompt = drafted }
    }

    private func draftAll() async {
        isDraftingAll = true
        for index in template.members.indices {
            draftingIndex = index
            let drafted = await model.draftTemplateMemberPrompt(template: template, memberIndex: index)
            if !drafted.isEmpty { template.members[index].rolePrompt = drafted }
        }
        draftingIndex = nil
        isDraftingAll = false
    }
}