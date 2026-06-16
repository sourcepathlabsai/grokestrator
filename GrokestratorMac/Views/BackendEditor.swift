import SwiftUI
import GrokestratorCore

/// Reusable editor for a single concrete `AgentBackend` — grok (the Node's own
/// command) or any OpenAI-compatible endpoint (Groq / Cerebras / xAI / Gemini /
/// local, via the provider presets). Binds to an `AgentBackend` and writes changes
/// back as the user edits. Used by the per-Node brain editor (`EditBrainView`) and
/// the host tier-map editor (`Settings ▸ Brains`).
///
/// API keys are referenced by *name* only; the value is resolved host-locally from
/// `.env.local_llm` and never written to config.
struct BackendEditor: View {
    @Binding var backend: AgentBackend

    private enum Kind: String, CaseIterable, Identifiable { case grok, api; var id: String { rawValue } }

    @State private var kind: Kind
    @State private var baseURL: String
    @State private var model: String
    @State private var keyRef: String

    init(backend: Binding<AgentBackend>) {
        _backend = backend
        switch backend.wrappedValue {
        case .grokACP:
            _kind = State(initialValue: .grok)
            _baseURL = State(initialValue: ""); _model = State(initialValue: ""); _keyRef = State(initialValue: "")
        case .openAICompatible(let url, let m, let ref):
            _kind = State(initialValue: .api)
            _baseURL = State(initialValue: url); _model = State(initialValue: m); _keyRef = State(initialValue: ref ?? "")
        case .gemini(let m, let ref):
            // Legacy/native shape — surface via the compat editor so it's editable.
            _kind = State(initialValue: .api)
            _baseURL = State(initialValue: BackendPreset.geminiBaseURL)
            _model = State(initialValue: m); _keyRef = State(initialValue: ref ?? "GEMINI_API_KEY")
        case .onboard:
            // Not yet runnable; show as grok so the editor never offers a dead backend.
            _kind = State(initialValue: .grok)
            _baseURL = State(initialValue: ""); _model = State(initialValue: ""); _keyRef = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Backend", selection: $kind) {
                Text("grok").tag(Kind.grok)
                Text("OpenAI-compatible").tag(Kind.api)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in push() }

            if kind == .grok {
                Text("Runs grok via the Node's command — the default. No API key needed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Provider").frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
                    Menu(currentPresetName) {
                        ForEach(BackendPreset.all) { p in Button(p.name) { apply(p) } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                field("Base URL", text: $baseURL, placeholder: "https://api.groq.com/openai/v1")
                field("Model", text: $model, placeholder: "llama-3.3-70b-versatile")
                field("API key name", text: $keyRef, placeholder: "GROQ_API_KEY")
                Text("The key *name* only — its value is read host-locally from .env.local_llm. Leave empty for keyless local servers.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: text.wrappedValue) { _, _ in push() }
        }
    }

    private var currentPresetName: String {
        BackendPreset.all.first { $0.baseURL == baseURL.trimmed }?.name ?? "Custom"
    }

    private func apply(_ p: BackendPreset) {
        baseURL = p.baseURL
        if model.trimmed.isEmpty { model = p.model }
        keyRef = p.keyRef
        push()
    }

    /// Write the current fields back to the bound `AgentBackend`.
    private func push() {
        switch kind {
        case .grok:
            backend = .grokACP
        case .api:
            let ref = keyRef.trimmed.isEmpty ? nil : keyRef.trimmed
            backend = .openAICompatible(baseURL: baseURL.trimmed, model: model.trimmed, apiKeyRef: ref)
        }
    }
}

/// A convenience preset for an OpenAI-compatible provider — fills base URL, a
/// sensible default model, and the host-local key name. Shared by every backend
/// editor so the provider list never drifts.
struct BackendPreset: Identifiable {
    let name: String
    let baseURL: String
    let model: String
    let keyRef: String
    var id: String { name }

    static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"

    static let all: [BackendPreset] = [
        BackendPreset(name: "Groq",            baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", keyRef: "GROQ_API_KEY"),
        BackendPreset(name: "Cerebras",        baseURL: "https://api.cerebras.ai/v1",     model: "llama-3.3-70b",           keyRef: "CEREBRAS_API_KEY"),
        BackendPreset(name: "xAI (Grok API)",  baseURL: "https://api.x.ai/v1",            model: "grok-2-latest",           keyRef: "XAI_API_KEY"),
        BackendPreset(name: "Gemini",          baseURL: geminiBaseURL,                    model: "gemini-2.0-flash",        keyRef: "GEMINI_API_KEY"),
        BackendPreset(name: "Local (LM Studio)", baseURL: "http://localhost:1234/v1",     model: "local-model",             keyRef: ""),
    ]
}

extension String {
    /// Whitespace-trimmed — shared by the backend editors.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
