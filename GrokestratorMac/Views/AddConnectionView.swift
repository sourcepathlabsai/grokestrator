import SwiftUI
import AppKit
import GrokestratorCore

/// Sheet for adding a local Connection — a `grok agent stdio` instance the
/// Mac will manage.
///
/// Name collision behavior:
/// - **Active duplicate** → inline error in the form; the Add button stays
///   blocked until the user changes the name.
/// - **Archived duplicate** → a confirm dialog offers **Restore** (un-archive,
///   most common intent) or **Create new** (rename the archived one with a
///   `(archived YYYY-MM-DD)` suffix so it stays unambiguous, then proceed).
struct AddConnectionView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, this is an "Add Child Agent" flow: the new Connection is
    /// created as a child of `parent`, which is auto-promoted to orchestrator.
    var parent: InstanceItem? = nil

    @State private var name = ""
    /// The brain backing this Connection. `grokACP` (default) launches a grok
    /// process via `command`/`arguments`; an OpenAI-compatible brain runs in-process
    /// (no child) and ignores them. Editable later via "Edit Brain…".
    @State private var backend: AgentBackend = .grokACP
    @State private var command = Self.defaultGrokPath
    @State private var argumentsText = "agent stdio"
    @State private var workingDirectory = ""
    @State private var autoRestart = true       // default on (memory: connection-semantics)
    @State private var shared = true            // default on (Tailscale is the trust boundary)

    /// Set while we're showing the archived-collision confirm. Carries the
    /// archived match so Restore / Create-new can act on it.
    @State private var pendingArchivedMatch: ManagedConnection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(parent == nil ? "Add Connection" : "Add Child Agent")
                .font(.headline)
                .padding()
            Divider()

            Form {
                if let parent {
                    HStack(spacing: 4) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.tint)
                        Text("Child of \"\(parent.name)\" — it becomes an orchestrator.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Name", text: $name, prompt: Text("Local Grok"))

                if let collision = activeCollision {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("A Connection named \"\(collision.name)\" already exists.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    BackendEditor(backend: $backend)
                } header: {
                    Text("Brain").font(.caption).foregroundStyle(.secondary)
                }

                if isGrok {
                    TextField("Command", text: $command)
                        .font(.system(.body, design: .monospaced))
                    TextField("Arguments", text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Working directory (optional)") {
                    HStack(spacing: 4) {
                        TextField("", text: $workingDirectory, prompt: Text("optional"))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(workingDirectoryIsValid ? Color.primary : Color.red)
                        Button {
                            selectWorkingDirectory()
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Choose a directory")
                    }
                }
                if !workingDirectoryIsValid {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("No such directory — grok can't launch here. Pick or fix the path.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Text(isGrok
                     ? "`grok agent stdio` runs the agent over stdio — the mode this app talks to."
                     : "The working directory is this brain's tool sandbox — its file/shell tools run there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-launch on Grokestrator startup", isOn: $autoRestart)
                Toggle("Share with remote Grokestrator clients", isOn: $shared)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: addTapped)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isAddDisabled)
            }
            .padding()
        }
        .frame(width: 480)
        .confirmationDialog(
            "An archived Connection named \"\(pendingArchivedMatch?.name ?? "")\" exists.",
            isPresented: archivedConfirmBinding,
            presenting: pendingArchivedMatch
        ) { archived in
            Button("Restore archived '\(archived.name)'") {
                model.restore(archived)
                pendingArchivedMatch = nil
                dismiss()
            }
            Button("Create new '\(archived.name)'") {
                renameArchivedAndAddNew(archived: archived)
            }
            Button("Cancel", role: .cancel) { pendingArchivedMatch = nil }
        } message: { _ in
            Text("You can bring back its config + transcript, or keep it archived and create a new one. The archived entry will be renamed so the two are easy to tell apart.")
        }
    }

    // MARK: - Validation

    private var finalName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Local Grok" : name
    }

    /// First active Connection that already uses this name (case-insensitive).
    /// `nil` ⇒ name is free.
    private var activeCollision: ManagedConnection? {
        model.activeConnection(named: finalName)
    }

    /// Whether the chosen brain launches grok (needs a `command`) vs. an in-process
    /// API brain (command/arguments are unused).
    private var isGrok: Bool { if case .grokACP = backend { return true }; return false }

    /// An OpenAI-compatible brain needs a base URL and a model; grok needs neither.
    private var backendIsValid: Bool {
        if case .openAICompatible(let url, let model, _) = backend {
            return !url.trimmed.isEmpty && !model.trimmed.isEmpty
        }
        return true
    }

    private var isAddDisabled: Bool {
        if isGrok, command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if !backendIsValid { return true }
        if activeCollision != nil { return true }
        if !workingDirectoryIsValid { return true }
        return false
    }

    /// Trimmed, tilde-expanded working directory, or `nil` when the field is
    /// blank (cwd is optional). Used both for validation and for the value
    /// actually handed to the launcher, so a typed `~/foo` resolves the same
    /// way the directory picker would write it.
    private var resolvedWorkingDirectory: String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// `true` when the field is blank or names an existing directory. A
    /// non-empty value that isn't a real directory is invalid — grok would
    /// fail to spawn there — so we turn the field red and block Add rather
    /// than let the launch fail after the fact.
    private var workingDirectoryIsValid: Bool {
        guard let path = resolvedWorkingDirectory else { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private var archivedConfirmBinding: Binding<Bool> {
        Binding(get: { pendingArchivedMatch != nil },
                set: { if !$0 { pendingArchivedMatch = nil } })
    }

    // MARK: - Actions

    private func addTapped() {
        // Active collision is already blocked by `isAddDisabled`; defense in depth.
        if activeCollision != nil { return }

        // Archived collision? Surface the chooser before doing anything.
        if let archived = model.archivedConnection(named: finalName) {
            pendingArchivedMatch = archived
            return
        }

        performAdd()
        dismiss()
    }

    private func renameArchivedAndAddNew(archived: ManagedConnection) {
        // `YYYY-MM-DD` from local components — simpler and concurrency-safe vs
        // a shared `ISO8601DateFormatter`. Locale doesn't matter; this is a
        // disambiguating tag in a name, not a localized date.
        let c = Calendar(identifier: .iso8601).dateComponents([.year, .month, .day], from: Date())
        let stamp = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        model.renameConnection(archived, to: "\(archived.name) (archived \(stamp))")
        pendingArchivedMatch = nil
        performAdd()
        dismiss()
    }

    private func performAdd() {
        let args = argumentsText.split(separator: " ").map(String.init)
        model.addRealConnection(name: finalName, command: command, arguments: args,
                                workingDirectory: resolvedWorkingDirectory, autoRestart: autoRestart, shared: shared,
                                parentID: parent?.id, brain: .pinned(backend))
    }

    /// Default to the per-user grok install location (resolved at runtime, not
    /// hardcoded). A GUI app bundle doesn't inherit the shell `PATH`, so a full
    /// path is required.
    private static var defaultGrokPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok")
            .path
    }

    // MARK: - Directory picker

    private func selectWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the working directory for this connection."

        // Seed the panel location from the current field value if valid.
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = url
            } else {
                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            }
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}
