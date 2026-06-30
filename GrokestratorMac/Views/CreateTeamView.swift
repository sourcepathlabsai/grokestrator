import SwiftUI
import GrokestratorCore

/// Sheet for stamping out an orchestrator + child agents from a `TeamTemplate`
/// in one step. The user picks a template, names the team, and configures the
/// shared runtime (command, working directory, brain). All members launch
/// immediately.
struct CreateTeamView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplate: TeamTemplate = TeamTemplate.builtins[0]
    @State private var teamName = ""
    @State private var brain: BrainBinding = .grok
    @State private var command = Self.defaultGrokPath
    @State private var argumentsText = "agent stdio"
    @State private var workingDirectory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create Team")
                .font(.headline)
                .padding()
            Divider()

            Form {
                // Template picker
                Section {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(TeamTemplate.builtins) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    Text(selectedTemplate.summary)
                        .font(.caption).foregroundStyle(.secondary)

                    // Preview members
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
                                Text(resolvedName(for: member, index: idx))
                                    .font(.system(.caption, design: .monospaced))
                                if idx == 0 {
                                    Text("(orchestrator)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                } header: {
                    Text("Template").font(.caption).foregroundStyle(.secondary)
                }

                // Team name
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

                // Brain picker (same as AddConnectionView)
                Section {
                    Picker("Brain", selection: brainSelection) {
                        Text("ACP Agent").tag(BrainSelection.grok)
                        ForEach(model.brainCatalog.profiles) { p in
                            Text(p.name).tag(BrainSelection.profile(p.id))
                        }
                    }
                } header: {
                    Text("Brain (shared by all members)").font(.caption).foregroundStyle(.secondary)
                }

                if isGrok {
                    TextField("Command", text: $command)
                        .font(.system(.body, design: .monospaced))
                    TextField("Arguments", text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                }

                // Working directory
                LabeledContent("Working directory (optional)") {
                    HStack(spacing: 4) {
                        TextField("", text: $workingDirectory, prompt: Text("optional"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(workingDirectoryIsValid ? Color.primary : Color.red)
                        Button {
                            selectWorkingDirectory()
                        } label: {
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
    }

    // MARK: - Validation

    private var finalBaseName: String {
        let trimmed = teamName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "team" : trimmed
    }

    private func resolvedName(for member: TeamTemplate.Member, index: Int) -> String {
        finalBaseName + member.nameSuffix
    }

    /// Check if any of the generated names collide with existing active connections.
    private var nameCollision: String? {
        for member in selectedTemplate.members {
            let name = finalBaseName + member.nameSuffix
            if model.activeConnection(named: name) != nil { return name }
        }
        return nil
    }

    private var isGrok: Bool { if case .grok = brain { return true }; return false }

    private enum BrainSelection: Hashable { case grok, profile(UUID) }
    private var brainSelection: Binding<BrainSelection> {
        Binding(
            get: { if case .profile(let id) = brain { return .profile(id) }; return .grok },
            set: { sel in
                switch sel {
                case .grok: brain = .grok
                case .profile(let id): brain = .profile(id)
                }
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

    private var isCreateDisabled: Bool {
        if isGrok, command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if case .profile(let id) = brain, model.brainCatalog.profile(id) == nil { return true }
        if nameCollision != nil { return true }
        if !workingDirectoryIsValid { return true }
        return false
    }

    // MARK: - Actions

    private func createTapped() {
        let args = argumentsText.split(separator: " ").map(String.init)
        model.createTeam(from: selectedTemplate, baseName: finalBaseName,
                         command: command, arguments: args,
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

// TeamTemplate needs Equatable + Hashable for SwiftUI Picker.
extension TeamTemplate: Equatable, Hashable {
    public static func == (lhs: TeamTemplate, rhs: TeamTemplate) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
