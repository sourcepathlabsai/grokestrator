import SwiftUI
import GrokestratorCore

/// Sheet for adding a local Connection — a `grok agent stdio` instance the
/// Mac will manage. (The "Mock" option that used to live alongside this is
/// gone — see `git log` on `MockConversationDriver` if you ever want it back.)
struct AddConnectionView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = Self.defaultGrokPath
    @State private var argumentsText = "agent stdio"
    @State private var workingDirectory = ""
    @State private var autoRestart = true       // default on (memory: connection-semantics)
    @State private var shared = true            // default on (Tailscale is the trust boundary)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Connection")
                .font(.headline)
                .padding()
            Divider()

            Form {
                TextField("Name", text: $name, prompt: Text("Local Grok"))

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
                Button("Add") {
                    add()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
    }

    private func add() {
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Local Grok" : name
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
