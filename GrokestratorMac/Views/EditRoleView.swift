import SwiftUI
import GrokestratorCore

/// Sheet for editing a Node's role/system prompt — what makes it behave as
/// Observe / Orient / Decide / Act, etc. The prompt is injected into the agent's
/// prompt stream (grok `agent stdio` ignores `--system-prompt-override`), so it
/// takes effect on the next turn. "Draft with grok" asks grok to write a first
/// pass from the agent's name and its team.
struct EditRoleView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var isDrafting = false
    @State private var loaded = false

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

                Text("Injected as a preamble on the agent's next turn. Leave empty for no role.")
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
                    model.setRolePrompt(text, for: item)
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

    private func draft() async {
        isDrafting = true
        let drafted = await model.draftRolePrompt(for: item)
        isDrafting = false
        if !drafted.isEmpty { text = drafted }
    }
}
