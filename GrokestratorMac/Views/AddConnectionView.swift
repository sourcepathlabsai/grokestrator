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
    /// The brain backing this Connection: grok (default — launches a grok process via
    /// `command`/`arguments`) or a catalog brain (in-process API; ignores them).
    /// Editable later via "Edit Brain…".
    @State private var brain: BrainBinding = .grok
    @State private var addingProfile = false
    @State private var command = Self.defaultGrokPath
    @State private var argumentsText = "agent stdio"
    @State private var workingDirectory = ""
    @State private var autoRestart = true       // default on (memory: connection-semantics)
    @State private var shared = true            // default on (Tailscale is the trust boundary)

    /// Set while we're showing the archived-collision confirm. Carries the
    /// archived match so Restore / Create-new can act on it.
    @State private var pendingArchivedMatch: ManagedConnection?

    /// Auto-detecting the Claude Code adapter (so the user never types its path).
    @State private var resolvingClaude = false
    /// Shown when Claude Code isn't installed yet — the detect/install flow.
    @State private var showingClaudeSetup = false

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
                    Picker("Brain", selection: brainSelection) {
                        Text("ACP Agent").tag(BrainSelection.grok)
                        ForEach(model.brainCatalog.profiles) { p in
                            Text(p.name).tag(BrainSelection.profile(p.id))
                        }
                    }
                    HStack(spacing: 12) {
                        // One tap: find the Homebrew/npm-installed `claude-code-acp`
                        // adapter, save it as a reusable "Claude Code" brain, and select
                        // it — so the user never has to know or type the adapter path.
                        Button { Task { await useClaudeCode() } } label: { Label("Use Claude Code", systemImage: "asterisk") }
                            .disabled(resolvingClaude)
                        Button { addingProfile = true } label: { Label("Add Brain to Catalog…", systemImage: "plus") }
                        if resolvingClaude { ProgressView().controlSize(.small) }
                    }
                    .buttonStyle(.borderless).font(.caption)
                } header: {
                    Text("Brain").font(.caption).foregroundStyle(.secondary)
                }

                if isGrok {
                    TextField("Command", text: $command)
                        .font(.system(.body, design: .monospaced))
                    TextField("Arguments", text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                    Text("ACP agent launch command — defaults to grok. For Claude Code, click **Use Claude Code** above (auto-detects the adapter — no path to type). Or paste any ACP-over-stdio command here. Detected: **\(GrokestratorModel.acpAgentLabel(forCommand: command))**.")
                        .font(.caption2).foregroundStyle(.tertiary)
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
        .sheet(isPresented: $addingProfile) { BrainProfileEditorView(model: model) }
        .sheet(isPresented: $showingClaudeSetup) {
            // Install-only sheet just sets up the adapter; on dismiss, select the Claude
            // brain here so the user finishes creating the Node in this one form.
            Task { await tryResolveClaudeSilently() }
        } content: {
            ClaudeCodeSetupView(model: model, installOnly: true)
        }
    }

    /// After the install sheet closes, quietly select the Claude brain if it resolved.
    private func tryResolveClaudeSilently() async {
        guard case .grok = brain, let adapter = await ClaudeCodeSetup.resolveAdapterPath() else { return }
        let id = model.brainCatalog.profiles.first(where: {
            if case .acpStdio(let cmd, _, _) = $0.backend { return cmd == adapter }
            return false
        })?.id ?? model.addBrainProfile(name: "Claude Code",
                                        backend: .acpStdio(command: adapter, arguments: [], label: "Claude Code"))
        command = adapter
        argumentsText = ""
        brain = .profile(id)
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

    /// A grok brain launches a process (needs `command`); a catalog brain runs
    /// in-process and ignores command/arguments.
    private var isGrok: Bool { if case .grok = brain { return true }; return false }

    /// Picker selection mapped to/from `brain` (only grok or a catalog profile are
    /// selectable at creation; dynamic/edit comes later via "Edit Brain…").
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

    private var isAddDisabled: Bool {
        if isGrok, command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        // A catalog brain must reference a profile that still exists.
        if case .profile(let id) = brain, model.brainCatalog.profile(id) == nil { return true }
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

    /// Auto-detect the Claude Code adapter, save/reuse a "Claude Code" catalog brain,
    /// and select it — the user never types or knows the adapter path. If it isn't
    /// installed, point them at the one-time installer rather than failing silently.
    private func useClaudeCode() async {
        resolvingClaude = true
        defer { resolvingClaude = false }
        guard let adapter = await ClaudeCodeSetup.resolveAdapterPath() else {
            // Not installed — drop straight into the detect/install flow instead of a
            // dead-end hint. That sheet handles Homebrew/node/adapter and creates the
            // Claude Node itself, so the user's goal is met there.
            showingClaudeSetup = true
            return
        }
        let id = model.brainCatalog.profiles.first(where: {
            if case .acpStdio(let cmd, _, _) = $0.backend { return cmd == adapter }
            return false
        })?.id ?? model.addBrainProfile(name: "Claude Code",
                                        backend: .acpStdio(command: adapter, arguments: [], label: "Claude Code"))
        command = adapter        // stored on the Connection too, as a fallback if the brain is deleted
        argumentsText = ""
        brain = .profile(id)     // select it → command fields collapse, picker shows "Claude Code"
    }

    private func performAdd() {
        let args = argumentsText.split(separator: " ").map(String.init)
        model.addRealConnection(name: finalName, command: command, arguments: args,
                                workingDirectory: resolvedWorkingDirectory, autoRestart: autoRestart, shared: shared,
                                parentID: parent?.id, brain: brain)
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
