import SwiftUI
import GrokestratorCore

/// Sheet for editing a Node's **brain binding** — which LLM backs it, and whether
/// that's hard-wired (`pinned`) or routed per task (`dynamic`). Saving swaps the
/// brain and restarts the Node so the next turn runs on the new backend; the
/// transcript reloads from history (see `model.setBrain`,
/// `design/12-model-agnostic-runtime.md`, Phase F).
///
/// The pinned backend is edited via the shared `BackendEditor` (grok or any
/// OpenAI-compatible endpoint). A dynamic binding picks a default tier + the tiers
/// it may use; the host tier map (Settings ▸ Brains) resolves those to backends.
struct EditBrainView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable { case pinned, dynamic; var id: String { rawValue } }

    @State private var mode: Mode = .pinned
    @State private var pinnedBackend: AgentBackend = .grokACP
    @State private var defaultTier: Tier = .balanced
    @State private var allowed: Set<Tier> = [.fast, .balanced, .deep]
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain").foregroundStyle(.tint)
                Text("Brain — \(item.name)").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Picker("Binding", selection: $mode) {
                    Text("Pinned").tag(Mode.pinned)
                    Text("Dynamic").tag(Mode.dynamic)
                }
                .pickerStyle(.segmented)

                if mode == .pinned {
                    BackendEditor(backend: $pinnedBackend)
                } else {
                    dynamicEditor
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
                Button("Save") {
                    model.setBrain(buildBinding(), for: item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear { loadOnce() }
    }

    private var isRunning: Bool { item.status == .running || item.status == .starting }

    // MARK: Dynamic

    @ViewBuilder private var dynamicEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Default tier").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: $defaultTier) {
                    ForEach(Tier.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(alignment: .top) {
                Text("Allowed").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        Toggle(tier.rawValue.capitalized, isOn: Binding(
                            get: { allowed.contains(tier) },
                            set: { on in
                                if on { allowed.insert(tier) } else { allowed.remove(tier) }
                                // The default tier must stay within the allowed set.
                                if !allowed.contains(defaultTier), let first = orderedAllowed.first {
                                    defaultTier = first
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Text("The orchestrator routes each task to a tier, clamped to the allowed set, resolved via the host tier map (Settings ▸ Brains). Per-task routing activates with Phase D; until then a dynamic Node runs on its default tier's backend.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var orderedAllowed: [Tier] { Tier.allCases.filter { allowed.contains($0) } }

    // MARK: Validation + build

    private var isValid: Bool {
        switch mode {
        case .pinned:
            if case .openAICompatible(let url, let m, _) = pinnedBackend {
                return !url.trimmed.isEmpty && !m.trimmed.isEmpty
            }
            return true
        case .dynamic:
            return !allowed.isEmpty && allowed.contains(defaultTier)
        }
    }

    private func buildBinding() -> BrainBinding {
        switch mode {
        case .pinned:  return .pinned(pinnedBackend)
        case .dynamic: return .dynamic(defaultTier: defaultTier, allowed: orderedAllowed)
        }
    }

    // MARK: Load

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        switch model.binding(for: item) {
        case .pinned(let backend):
            mode = .pinned
            pinnedBackend = backend
        case .dynamic(let dft, let allow):
            mode = .dynamic
            defaultTier = dft
            allowed = Set(allow.isEmpty ? [dft] : allow)
        }
    }
}
