import SwiftUI
import GrokestratorCore

/// Tabbed `.grok/` config editor for ACP harness teams (`design/10` rung 2, #132).
struct GrokConfigEditorView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .agent
    @State private var scope: GrokConfigScope = .project
    @State private var agent = GrokAgentDraft(name: "coordinator")
    @State private var roles: [GrokRoleDraft] = []
    @State private var personas: [GrokPersonaDraft] = []
    @State private var selectedTemplateID: String = GrokHarnessTemplate.plain.id
    private var selectedTemplate: GrokHarnessTemplate {
        GrokHarnessTemplate.all.first(where: { $0.id == selectedTemplateID }) ?? .plain
    }
    @State private var showingPreview = false
    @State private var pendingPlan: GrokConfigWritePlan?
    @State private var overwriteExisting = false
    @State private var statusMessage: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case connection, agent, team, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .connection: return "Connection"
            case .agent: return "Agent"
            case .team: return "Team"
            case .advanced: return "Advanced"
            }
        }
    }

    private var projectCWD: String? {
        model.connections.first(where: { $0.id == item.id })?.workingDirectory
            ?? item.conversation.capabilities?.workingDirectory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                tabContent
                    .padding()
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .onAppear { loadFromConnection() }
        .sheet(isPresented: $showingPreview) {
            if let plan = pendingPlan {
                GrokConfigDiffPreview(plan: plan, overwrite: $overwriteExisting) {
                    applyPlan(plan)
                    showingPreview = false
                } onCancel: {
                    showingPreview = false
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2").foregroundStyle(.tint)
            Text("Grok Config — \(item.name)").font(.headline)
        }
        .padding()
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .connection:
            connectionTab
        case .agent:
            agentTab
        case .team:
            teamTab
        case .advanced:
            advancedTab
        }
    }

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection fields live in Grokestrator's registry. Use Edit Role / Brain / Tools from the sidebar for runtime settings.")
                .font(.caption).foregroundStyle(.secondary)
            if let conn = model.connections.first(where: { $0.id == item.id }) {
                LabeledContent("Command") { Text(conn.command).font(.system(.body, design: .monospaced)) }
                LabeledContent("Arguments") { Text(conn.arguments.joined(separator: " ")).font(.system(.body, design: .monospaced)) }
                if let cwd = conn.workingDirectory {
                    LabeledContent("Working directory") { Text(cwd).font(.system(.body, design: .monospaced)) }
                }
            }
        }
    }

    private var agentTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopePicker
            TextField("Agent name", text: $agent.name)
            TextField("Description", text: $agent.description)
            TextField("Model", text: $agent.model)
                .font(.system(.body, design: .monospaced))
            Text("System prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $agent.systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var teamTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopePicker
            Picker("Template", selection: $selectedTemplateID) {
                ForEach(GrokHarnessTemplate.all) { t in
                    Text(t.title).tag(t.id)
                }
            }
            .onChange(of: selectedTemplateID) { _, id in
                if let t = GrokHarnessTemplate.all.first(where: { $0.id == id }) { loadTemplate(t) }
            }

            Text(selectedTemplate.summary)
                .font(.caption).foregroundStyle(.secondary)

            if !roles.isEmpty {
                Text("Roles").font(.caption).foregroundStyle(.secondary)
                ForEach(roles) { role in
                    Text("• \(role.name) — \(role.description)")
                        .font(.caption)
                }
            }
            if !personas.isEmpty {
                Text("Personas").font(.caption).foregroundStyle(.secondary)
                ForEach(personas) { p in
                    Text("• \(p.name)")
                        .font(.caption)
                }
            }
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            scopePicker
            Text("Files are written to \(scope.baseDirectory(projectCWD: projectCWD).path)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Hand-authored `.grok/` files can be imported by loading a template or editing the Agent tab, then previewing the diff before save.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apply to").font(.caption).foregroundStyle(.secondary)
            Picker("Scope", selection: $scope) {
                ForEach(GrokConfigScope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Preview & Save…") { previewSave() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func loadFromConnection() {
        let slug = item.name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let loaded = GrokConfigWriter.loadAgent(name: slug, scope: .project, projectCWD: projectCWD) {
            agent = loaded
        } else {
            agent.name = slug
        }
    }

    private func loadTemplate(_ template: GrokHarnessTemplate) {
        agent = template.agent
        roles = template.roles
        personas = template.personas
    }

    private func previewSave() {
        let plan: GrokConfigWritePlan
        if selectedTemplate.id != "plain" && tab == .team {
            plan = GrokConfigWriter.plan(template: selectedTemplate, scope: scope, projectCWD: projectCWD, agentNameOverride: agent.name)
        } else {
            plan = GrokConfigWriter.planCustom(agent: agent, roles: roles, personas: personas, scope: scope, projectCWD: projectCWD)
        }
        guard !plan.operations.isEmpty else {
            statusMessage = "Nothing to write — pick a team template or edit the agent."
            return
        }
        pendingPlan = plan
        overwriteExisting = plan.overwrites.isEmpty
        showingPreview = true
    }

    private func applyPlan(_ plan: GrokConfigWritePlan) {
        do {
            let n = try GrokConfigWriter.apply(plan, overwriteExisting: overwriteExisting)
            statusMessage = "Wrote \(n) file\(n == 1 ? "" : "s") to \(plan.scope.label)."
            dismiss()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct GrokConfigDiffPreview: View {
    let plan: GrokConfigWritePlan
    @Binding var overwrite: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preview changes").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.creates.isEmpty {
                        Text("Create (\(plan.creates.count))").font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.creates) { op in
                            fileRow(op, tint: .green)
                        }
                    }
                    if !plan.overwrites.isEmpty {
                        Toggle("Overwrite existing files", isOn: $overwrite)
                        Text("Overwrite (\(plan.overwrites.count))").font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.overwrites) { op in
                            fileRow(op, tint: .orange)
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Write files", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.overwrites.isEmpty && !overwrite && plan.creates.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    private func fileRow(_ op: GrokConfigWritePlan.FileOp, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(op.relativePath).font(.system(.body, design: .monospaced)).foregroundStyle(tint)
            Text(String(op.newContent.prefix(200)) + (op.newContent.count > 200 ? "…" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

