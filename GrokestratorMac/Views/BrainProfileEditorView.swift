import SwiftUI
import GrokestratorCore

/// Sheet to create or edit a catalog `BrainProfile` — a named, reusable brain
/// (provider + model + key) that Nodes and tiers point at. Multiple per service is
/// the point: curate "Cerebras · GPT-OSS 120B" and "Cerebras · Llama-4 Scout" as
/// separate brains and pick the one fit for each task.
struct BrainProfileEditorView: View {
    @Bindable var model: GrokestratorModel
    /// The profile being edited; `nil` ⇒ creating a new one.
    let existing: BrainProfile?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var backend: AgentBackend
    @State private var nameEdited: Bool

    init(model: GrokestratorModel, existing: BrainProfile? = nil) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _backend = State(initialValue: existing?.backend
                         ?? .openAICompatible(baseURL: "", model: "", apiKeyRef: nil))
        _nameEdited = State(initialValue: existing != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain").foregroundStyle(.tint)
                Text(existing == nil ? "New Brain" : "Edit Brain").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Name").frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
                    TextField(suggestedName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, _ in nameEdited = true }
                }
                BackendEditor(backend: $backend)
            }
            .padding()

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560)
    }

    /// Auto-name from the backend until the user types their own.
    private var suggestedName: String { GrokestratorModel.defaultName(for: backend) }

    private var finalName: String {
        let n = name.trimmed
        return n.isEmpty ? suggestedName : n
    }

    private var isValid: Bool {
        if case .openAICompatible(let url, let model, _) = backend {
            return !url.trimmed.isEmpty && !model.trimmed.isEmpty
        }
        return false
    }

    private func save() {
        if let existing {
            model.updateBrainProfile(BrainProfile(id: existing.id, name: finalName, backend: backend))
        } else {
            model.addBrainProfile(name: finalName, backend: backend)
        }
        dismiss()
    }
}
