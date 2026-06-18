import SwiftUI
import GrokestratorCore

/// Editor for an OpenAI-compatible backend (provider + model + key name) — the body
/// of a catalog `BrainProfile`. Binds to an `AgentBackend` and always produces
/// `.openAICompatible`. Provider presets fill base URL + key name + a starter model;
/// "Fetch models" lists the provider's live models so the choice is never stale.
///
/// API keys are referenced by *name* only; the value is entered here and stored
/// host-locally in `.env.local_llm` via `Secrets` — never in config.
struct BackendEditor: View {
    @Binding var backend: AgentBackend

    @State private var baseURL: String
    @State private var model: String
    @State private var keyRef: String
    @State private var newKeyValue: String = ""
    @State private var keyStatusTick = 0
    @State private var keyReplaceMode = false

    @State private var fetchedModels: [String] = []
    @State private var fetching = false
    @State private var fetchError: String?

    init(backend: Binding<AgentBackend>) {
        _backend = backend
        switch backend.wrappedValue {
        case .openAICompatible(let url, let m, let ref):
            _baseURL = State(initialValue: url); _model = State(initialValue: m); _keyRef = State(initialValue: ref ?? "")
        case .gemini(let m, let ref):
            _baseURL = State(initialValue: BackendPreset.geminiBaseURL)
            _model = State(initialValue: m); _keyRef = State(initialValue: ref ?? "GEMINI_API_KEY")
        case .grokACP, .onboard, .acpStdio:
            // This editor edits API brains; for non-API backends start from a blank
            // OpenAI-compatible shape (ACP-stdio brains are created via Claude setup).
            _baseURL = State(initialValue: ""); _model = State(initialValue: ""); _keyRef = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Provider").frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
                Menu(currentPresetName) {
                    Button("New Provider") { applyNewProvider() }
                    Divider()
                    ForEach(BackendPreset.all) { p in Button(p.name) { apply(p) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            field("Base URL", text: $baseURL, placeholder: "https://api.your-provider.com/v1")
            // API key (name + value) sits ABOVE the model on purpose: fetching the
            // model list needs the base URL *and* a working key.
            field("Key name", text: $keyRef, placeholder: "PROVIDER_API_KEY")
            keyStatusRow
            Text("The key value is stored host-locally in .env.local_llm (0600, gitignored) under this name — never in config. Pick a known provider above and the name fills in; leave empty only for keyless local servers.")
                .font(.caption2).foregroundStyle(.tertiary)
            // Model — fetched from the provider, left blank until you pick one.
            modelRow
        }
    }

    // MARK: Model row (+ live fetch)

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model").frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
                TextField("Fetch, then pick a model", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: model) { _, _ in push() }
                if !fetchedModels.isEmpty {
                    Menu("Pick") {
                        ForEach(fetchedModels, id: \.self) { m in
                            Button(m) { model = m; push() }
                        }
                    }
                    .frame(width: 64)
                }
                Button {
                    Task { await fetchModels() }
                } label: {
                    if fetching { ProgressView().controlSize(.small) } else { Text("Fetch") }
                }
                .disabled(fetching || baseURL.trimmed.isEmpty)
                .help("List the provider's available models")
            }
            if let fetchError {
                Text(fetchError).font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func fetchModels() async {
        fetching = true; fetchError = nil
        defer { fetching = false }
        do {
            let models = try await BrainModelList.fetch(baseURL: baseURL.trimmed, apiKeyRef: keyRef.trimmed)
            fetchedModels = models
            if models.isEmpty { fetchError = "No models returned." }
        } catch {
            fetchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fetchedModels = []
        }
    }

    // MARK: Key entry

    @ViewBuilder private var keyStatusRow: some View {
        let ref = keyRef.trimmed
        let _ = keyStatusTick
        if !ref.isEmpty {
            if Secrets.hasValue(for: ref) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Key on file for \(ref)").font(.caption)
                    Spacer()
                    Button("Replace…") { keyReplaceMode = true; keyStatusTick += 1 }
                        .buttonStyle(.link).font(.caption)
                        .opacity(keyReplaceMode ? 0 : 1)
                }
                if keyReplaceMode { keyEntryField(ref) }
            } else {
                keyEntryField(ref)
            }
        }
    }

    private func keyEntryField(_ ref: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("API key").frame(width: 78, alignment: .leading).foregroundStyle(.secondary)
            SecureField("Paste the provider's API key", text: $newKeyValue)
                .textFieldStyle(.roundedBorder)
            Button("Save key") {
                if Secrets.set(newKeyValue, for: ref) {
                    newKeyValue = ""
                    keyReplaceMode = false
                    keyStatusTick += 1
                }
            }
            .disabled(newKeyValue.trimmed.isEmpty)
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
        BackendPreset.all.first { $0.baseURL == baseURL.trimmed }?.name ?? "New Provider"
    }

    /// Apply a known provider: fills base URL + key name, but NOT a model — the model
    /// list is fetched and picked, never guessed.
    private func apply(_ p: BackendPreset) {
        baseURL = p.baseURL
        model = ""
        keyRef = p.keyRef
        fetchedModels = []; fetchError = nil
        push()
    }

    /// Start from a blank "New Provider" shape (clears the preset's fields).
    private func applyNewProvider() {
        baseURL = ""; model = ""; keyRef = ""
        fetchedModels = []; fetchError = nil
        push()
    }

    /// Write the current fields back to the bound `AgentBackend` (always API-shaped).
    private func push() {
        let ref = keyRef.trimmed.isEmpty ? nil : keyRef.trimmed
        backend = .openAICompatible(baseURL: baseURL.trimmed, model: model.trimmed, apiKeyRef: ref)
    }
}

/// A convenience preset for an OpenAI-compatible provider — fills base URL, a
/// starter model, and the host-local key name. Shared so the provider list and key
/// names never drift across editors. The starter model is just a seed; users curate
/// their own via "Fetch models" / the catalog.
struct BackendPreset: Identifiable {
    let name: String
    let baseURL: String
    let model: String
    let keyRef: String
    var id: String { name }

    static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"

    static let all: [BackendPreset] = [
        BackendPreset(name: "Groq",            baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile", keyRef: "GROQ_API_KEY"),
        BackendPreset(name: "Cerebras",        baseURL: "https://api.cerebras.ai/v1",     model: "gpt-oss-120b",            keyRef: "CEREBRAS_API_KEY"),
        BackendPreset(name: "xAI (Grok API)",  baseURL: "https://api.x.ai/v1",            model: "grok-4.3",                keyRef: "GROK_API_KEY"),
        BackendPreset(name: "Gemini",          baseURL: geminiBaseURL,                    model: "gemini-2.5-flash",        keyRef: "GEMINI_API_KEY"),
        BackendPreset(name: "Local (LM Studio)", baseURL: "http://localhost:1234/v1",     model: "",                        keyRef: ""),
    ]
}

extension String {
    /// Whitespace-trimmed — shared by the backend editors.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
