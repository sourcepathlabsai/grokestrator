import SwiftUI
import GrokestratorCore

/// Sheet for stamping out an orchestrator + child agents from a `TeamTemplate`
/// in one step. Fleet templates require API/local brains (`design/10`).
struct CreateTeamView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String = ""
    @State private var teamName = ""
    @State private var brain: BrainBinding = .grok
    @State private var command = Self.defaultGrokPath
    @State private var argumentsText = "agent stdio"
    @State private var workingDirectory = ""

    private var templates: [TeamTemplate] { model.fleetTeamTemplates }

    private var selectedTemplate: TeamTemplate {
        templates.first(where: { $0.id == selectedTemplateID }) ?? templates.first ?? TeamTemplate.codeReview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create Fleet Team")
                .font(.headline)
                .padding()
            Divider()

            Form {
                Section {
                    Text("Orchestrated fleet — Grokestrator coordinates child Connections via `delegate`. Requires an API or local brain (not grok/ACP).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Template", selection: $selectedTemplateID) {
                        ForEach(templates) { t in
                            Text(t.title).tag(t.id)
                        }
                    }
                    Text(selectedTemplate.summary)
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Members:").font(.caption2).foregroundStyle(.tertiary)
                        ForEach(Array(selectedTemplate.members.enumerated()), id: \.offset) { idx, member in
                            HStack(spacing: 6) {
                                Image(systemName: idx == 0
                                      ? "point.3.connected.trianglepath.dotted"
                                      : "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(idx == 0 ? .cyan : .secondary)
                                    .frame(width: 14)
                                Text(member.displayName)
                                    .font(.caption)
                                Text(resolvedName(for: member, index: idx))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, 4)
                } header: {
                    Text("Template").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextField("Team Name", text: $teamName, prompt: Text("review"))
                    if let collision = nameCollision {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("A Connection named \"\(collision)\" already exists.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Each member is named **\(finalBaseName)** + a role suffix.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if model.brainCatalog.profiles.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Add an API brain in Settings before creating a fleet team.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Brain", selection: brainSelection) {
                            ForEach(model.brainCatalog.profiles) { p in
                                Text(p.name).tag(BrainSelection.profile(p.id))
                            }
                        }
                        Text("Shared by all team members. ACP agents use harness subagents instead — use Add Connection for those.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Brain (API / local)").font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Working directory (optional)") {
                    HStack(spacing: 4) {
                        TextField("", text: $workingDirectory, prompt: Text("optional"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(workingDirectoryIsValid ? Color.primary : Color.red)
                        Button { selectWorkingDirectory() } label: {
                            Image(systemName: "folder").font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                if !workingDirectoryIsValid {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("No such directory.").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Team") { createTapped() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreateDisabled)
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 400)
        .onAppear {
            bootstrapBrain()
            if selectedTemplateID.isEmpty, let first = templates.first {
                selectedTemplateID = first.id
            }
        }
    }

    private func bootstrapBrain() {
        if case .profile = brain { return }
        if let first = model.brainCatalog.profiles.first {
            brain = .profile(first.id)
        }
    }

    // MARK: - Validation

    private var finalBaseName: String {
        let trimmed = teamName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "team" : trimmed
    }

    private func resolvedName(for member: TeamTemplate.Member, index: Int) -> String {
        finalBaseName + member.nameSuffix
    }

    private var nameCollision: String? {
        for member in selectedTemplate.members {
            let name = finalBaseName + member.nameSuffix
            if model.activeConnection(named: name) != nil { return name }
        }
        return nil
    }

    private enum BrainSelection: Hashable { case profile(UUID) }
    private var brainSelection: Binding<BrainSelection> {
        Binding(
            get: {
                if case .profile(let id) = brain { return .profile(id) }
                if let first = model.brainCatalog.profiles.first { return .profile(first.id) }
                return .profile(UUID())
            },
            set: { sel in
                if case .profile(let id) = sel { brain = .profile(id) }
            }
        )
    }

    private var resolvedWorkingDirectory: String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private var workingDirectoryIsValid: Bool {
        guard let path = resolvedWorkingDirectory else { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private var fleetBrainOK: Bool {
        model.supportsFleetOrchestration(brain: brain) && model.brainCatalog.profile(brain.profileID ?? UUID()) != nil
    }

    private var isCreateDisabled: Bool {
        if model.brainCatalog.profiles.isEmpty { return true }
        if !fleetBrainOK { return true }
        if nameCollision != nil { return true }
        if !workingDirectoryIsValid { return true }
        return false
    }

    // MARK: - Actions

    private func createTapped() {
        guard fleetBrainOK, case .profile(let id) = brain,
              let profile = model.brainCatalog.profile(id) else { return }
        switch profile.backend {
        case .grokACP, .acpStdio: return
        default: break
        }
        model.createTeam(from: selectedTemplate, baseName: finalBaseName,
                         command: Self.defaultGrokPath, arguments: [],
                         workingDirectory: resolvedWorkingDirectory, brain: brain)
        dismiss()
    }

    private func selectWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = url
            }
        }
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private static var defaultGrokPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok")
            .path
    }
}

