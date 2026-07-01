import SwiftUI
import GrokestratorCore

/// Sheet for editing a Node's role/system prompt — what makes it behave as
/// Observe / Orient / Decide / Act, etc. The prompt is injected into the agent's
/// prompt stream (grok `agent stdio` ignores `--system-prompt-override`).
/// Default save restarts the Node with a compact prior-context gist (issue #177).
struct EditRoleView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var isDrafting = false
    @State private var loaded = false
    @State private var saveMode: GrokestratorModel.RoleSaveMode = .restartWithGist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: item.role == .orchestrator
                      ? "point.3.connected.trianglepath.dotted" : "person")
                    .foregroundStyle(.tint)
                Text("Role — \(item.name)").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(item.role == .orchestrator
                     ? "How this orchestrator coordinates its children and decides what to do."
                     : "What this agent is responsible for.")
                    .font(.caption).foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .opacity(isDrafting ? 0.5 : 1)
                    .overlay {
                        if isDrafting {
                            ProgressView("Drafting with grok…").controlSize(.small)
                        }
                    }

                Picker("Apply as", selection: $saveMode) {
                    Text("Restart with compact context").tag(GrokestratorModel.RoleSaveMode.restartWithGist)
                    Text("Re-prime only (no restart)").tag(GrokestratorModel.RoleSaveMode.reprimeOnly)
                    Text("Fresh restart (no carry-forward)").tag(GrokestratorModel.RoleSaveMode.restartFresh)
                }
                .pickerStyle(.radioGroup)

                Text(helpText)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()

            Divider()
            HStack {
                Button {
                    Task { await draft() }
                } label: {
                    Label("Draft with grok", systemImage: "sparkles")
                }
                .disabled(isDrafting)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setRolePrompt(text, for: item, mode: saveMode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isDrafting)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = item.rolePrompt ?? ""
        }
    }

    private var helpText: String {
        switch saveMode {
        case .restartWithGist:
            return "Restarts the agent and injects a compact summary of prior outcomes — not the full transcript. Recommended when changing roles."
        case .reprimeOnly:
            return "Prepends the new role on the next turn only. The live session may still remember the old role."
        case .restartFresh:
            return "Restarts with an empty agent session. The UI transcript is kept; the agent starts with no prior context."
        }
    }

    private func draft() async {
        isDrafting = true
        let drafted = await model.draftRolePrompt(for: item)
        isDrafting = false
        if !drafted.isEmpty { text = drafted }
    }
}