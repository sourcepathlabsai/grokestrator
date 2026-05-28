import SwiftUI
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

    @State private var name = ""
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
            Text("Add Connection")
                .font(.headline)
                .padding()
            Divider()

            Form {
                TextField("Name", text: $name, prompt: Text("Local Grok"))

                if let collision = activeCollision {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("A Connection named \"\(collision.name)\" already exists.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                TextField("Command", text: $command)
                    .font(.system(.body, design: .monospaced))
                TextField("Arguments", text: $argumentsText)
                    .font(.system(.body, design: .monospaced))
                TextField("Working directory (optional)", text: $workingDirectory)
                    .font(.system(.body, design: .monospaced))
                Text("`grok agent stdio` runs the agent over stdio — the mode this app talks to.")
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

    private var isAddDisabled: Bool {
        if command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if activeCollision != nil { return true }
        return false
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
        let cwd = workingDirectory.trimmingCharacters(in: .whitespaces).isEmpty ? nil : workingDirectory
        model.addRealConnection(name: finalName, command: command, arguments: args,
                                workingDirectory: cwd, autoRestart: autoRestart, shared: shared)
    }

    /// Default to the per-user grok install location (resolved at runtime, not
    /// hardcoded). A GUI app bundle doesn't inherit the shell `PATH`, so a full
    /// path is required.
    private static var defaultGrokPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok")
            .path
    }
}
