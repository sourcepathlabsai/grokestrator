import SwiftUI
import GrokestratorCore

/// Sheet for setting a Node's **brain** — grok (its own command), a **catalog
/// brain** (a named provider+model you curate in Settings ▸ Brains), or **dynamic**
/// (tier-routed, resolved through the host tier map). Saving restarts the Node so
/// the next turn runs on the new brain; the transcript reloads from history.
/// See `model.setBrain`, `design/12-model-agnostic-runtime.md` (Phase F).
struct EditBrainView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable { case grok, brain, dynamic; var id: String { rawValue } }

    @State private var mode: Mode = .grok
    @State private var profileID: UUID?
    @State private var defaultTier: Tier = .balanced
    @State private var allowed: Set<Tier> = [.fast, .balanced, .deep]
    @State private var loaded = false
    @State private var addingProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain").foregroundStyle(.tint)
                Text("Brain — \(item.name)").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Picker("Brain", selection: $mode) {
                    Text("ACP Agent").tag(Mode.grok)
                    Text("Catalog brain").tag(Mode.brain)
                    Text("Dynamic").tag(Mode.dynamic)
                }
                .pickerStyle(.segmented)

                switch mode {
                case .grok:    grokInfo
                case .brain:   catalogPicker
                case .dynamic: dynamicEditor
                }
            }
            .padding()

            Divider()
            HStack {
                if isRunning {
                    Label("Saving restarts this Node", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setBrain(buildBinding(), for: item); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear { loadOnce() }
        .sheet(isPresented: $addingProfile) { BrainProfileEditorView(model: model) }
    }

    private var isRunning: Bool { item.status == .running || item.status == .starting }

    // MARK: Sections

    @ViewBuilder private var grokInfo: some View {
        let agent = model.acpAgentLabel(for: item)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.tint)
                Text("This Node runs **\(agent)** as an agent over ACP (its launch command).")
                    .font(.caption)
            }
            Text("grok and Claude Code are both ACP agents; the launch command picks which. Change it in the Add-Connection flow, or use “Add Claude Code Agent…”. No API key needed here.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var catalogPicker: some View {
        let profiles = model.brainCatalog.profiles
        if profiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No catalog brains yet. Create one (Groq, Cerebras, xAI, Gemini, local…) and point this Node at it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { addingProfile = true } label: { Label("Add Brain…", systemImage: "plus") }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Brain").frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                    Picker("", selection: $profileID) {
                        ForEach(profiles) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .labelsHidden()
                    Button { addingProfile = true } label: { Image(systemName: "plus") }
                        .help("Add a new brain to the catalog")
                }
                if let id = profileID, let p = model.brainCatalog.profile(id) {
                    Text(summary(p.backend)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Manage brains and models in Settings ▸ Brains.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var dynamicEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Default tier").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: $defaultTier) {
                    ForEach(Tier.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack(alignment: .top) {
                Text("Allowed").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        Toggle(tier.rawValue.capitalized, isOn: Binding(
                            get: { allowed.contains(tier) },
                            set: { on in
                                if on { allowed.insert(tier) } else { allowed.remove(tier) }
                                if !allowed.contains(defaultTier), let first = orderedAllowed.first {
                                    defaultTier = first
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Text("The orchestrator routes each task to a tier, clamped to the allowed set, resolved via the host tier map (Settings ▸ Brains). Per-task routing activates with Phase D; until then a dynamic Node uses its default tier.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var orderedAllowed: [Tier] { Tier.allCases.filter { allowed.contains($0) } }

    private func summary(_ backend: AgentBackend) -> String {
        if case .openAICompatible(let url, let model, _) = backend { return "\(model) @ \(url)" }
        return GrokestratorModel.defaultName(for: backend)
    }

    // MARK: Validation + build

    private var isValid: Bool {
        switch mode {
        case .grok:    return true
        case .brain:   return profileID != nil && model.brainCatalog.profile(profileID!) != nil
        case .dynamic: return !allowed.isEmpty && allowed.contains(defaultTier)
        }
    }

    private func buildBinding() -> BrainBinding {
        switch mode {
        case .grok:    return .grok
        case .brain:   return profileID.map { BrainBinding.profile($0) } ?? .grok
        case .dynamic: return .dynamic(defaultTier: defaultTier, allowed: orderedAllowed)
        }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        switch model.binding(for: item) {
        case .grok, .inlineLegacy:
            mode = .grok
        case .profile(let id):
            mode = .brain; profileID = id
        case .dynamic(let dft, let allow):
            mode = .dynamic; defaultTier = dft; allowed = Set(allow.isEmpty ? [dft] : allow)
        }
        // Default the catalog picker to the first brain when entering brain mode fresh.
        if profileID == nil { profileID = model.brainCatalog.profiles.first?.id }
    }
}
