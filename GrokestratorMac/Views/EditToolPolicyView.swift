import SwiftUI
import GrokestratorCore

/// Sheet for editing a Node's **tool/capability policy** — what its brain is
/// allowed to *do*. This is the app-owned guardrail layer (design/11 guardrails,
/// design/12 Phase C): a `capability` tier bounds the kind of action, and an
/// optional allowlist narrows to specific tools within that tier.
///
/// Enforced for **model-agnostic (API) brains**, where the app runs the tool loop
/// (`OpenAICompatSession.isPermitted`). A grok-backed Node manages its own tools, so
/// the policy is advisory there — the sheet says so. Saving restarts a running Node
/// so the new policy takes effect (the tool loop captures it at session creation).
struct EditToolPolicyView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    /// A concrete app-executed tool and the capability tier it needs. Mirrors
    /// `OpenAICompatSession.isPermitted` so the editor offers exactly the real tools.
    private struct Tool: Identifiable {
        let name: String
        let label: String
        let systemImage: String
        let requires: ToolPolicy.Capability   // `.delegate` handled separately (orchestration-gated)
        var id: String { name }
    }

    private static let fileTools: [Tool] = [
        Tool(name: "read_file",   label: "Read files",       systemImage: "doc.text",          requires: .readOnly),
        Tool(name: "list_dir",    label: "List directories", systemImage: "folder",            requires: .readOnly),
        Tool(name: "write_file",  label: "Write files",      systemImage: "square.and.pencil", requires: .readWrite),
        Tool(name: "run_command", label: "Run commands",     systemImage: "terminal",          requires: .execute),
    ]
    private static let delegateTool = Tool(name: "delegate", label: "Delegate to children",
                                           systemImage: "point.3.connected.trianglepath.dotted",
                                           requires: .readOnly)   // gated by orchestration, not a file tier

    @State private var capability: ToolPolicy.Capability = .execute
    /// Tools the user has explicitly enabled. Persisted as `allowed`, except when it
    /// equals the full permitted set (then `allowed = nil`, meaning "no allowlist").
    @State private var enabled: Set<String> = []
    @State private var loaded = false

    private var isOrchestrator: Bool { item.role == .orchestrator }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(.tint)
                Text("Tools — \(item.name)").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Capability").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $capability) {
                        Text("Read-only").tag(ToolPolicy.Capability.readOnly)
                        Text("Read & write").tag(ToolPolicy.Capability.readWrite)
                        Text("Execute").tag(ToolPolicy.Capability.execute)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: capability) { _, _ in pruneToCapability() }
                    Text(capabilityBlurb).font(.caption2).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Allowed tools").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(allText) { toggleAll() }
                            .buttonStyle(.link).font(.caption)
                    }
                    ForEach(permittedTools) { tool in
                        Toggle(isOn: Binding(
                            get: { enabled.contains(tool.name) },
                            set: { on in if on { enabled.insert(tool.name) } else { enabled.remove(tool.name) } }
                        )) {
                            Label(tool.label, systemImage: tool.systemImage)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(enabled.isEmpty
                         ? "No tools enabled — this Node can only converse (every tool call is denied)."
                         : "Tools left unchecked are denied even when the capability would permit them.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding()

            Divider()
            HStack {
                Image(systemName: brainIsGrok ? "info.circle" : "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text(brainIsGrok
                     ? "This Node runs \(model.acpAgentLabel(for: item)) (an ACP agent), which manages its own tools — the policy applies to API-model brains."
                     : "Enforced by the app's tool loop for this Node's API brain.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setToolPolicy(buildPolicy(), for: item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 560)
        .onAppear { loadOnce() }
    }

    // MARK: Derived

    private var brainIsGrok: Bool {
        switch model.binding(for: item) {
        case .grok, .inlineLegacy: return true
        // A dynamic Node whose default tier maps to grok also runs grok today
        // (tier routing lands in Phase D); a profile-pinned Node runs an API brain.
        case .dynamic(let defaultTier, _):
            if case .grok = model.hostTierMap.ref(for: defaultTier) { return true }
            return false
        case .profile:
            return false
        }
    }

    /// Tools selectable at the current capability: the file tools whose tier the
    /// capability covers, plus `delegate` for an orchestrator.
    private var permittedTools: [Tool] {
        var out = Self.fileTools.filter { rank($0.requires) <= rank(capability) }
        if isOrchestrator { out.append(Self.delegateTool) }
        return out
    }

    private var capabilityBlurb: String {
        switch capability {
        case .readOnly:  return "Read and list files only — no writes, no shell."
        case .readWrite: return "Read, list, and write files — no shell."
        case .execute:   return "Full access, including running shell commands."
        }
    }

    private var allText: String { isAllOn ? "Clear all" : "Allow all" }
    private var isAllOn: Bool { enabled.isSuperset(of: permittedTools.map(\.name)) && !permittedTools.isEmpty }

    private func rank(_ c: ToolPolicy.Capability) -> Int {
        switch c { case .readOnly: return 0; case .readWrite: return 1; case .execute: return 2 }
    }

    // MARK: Mutations

    private func toggleAll() {
        let names = permittedTools.map(\.name)
        if isAllOn { names.forEach { enabled.remove($0) } } else { enabled.formUnion(names) }
    }

    /// Drop any enabled tool the (newly lowered) capability no longer permits, so the
    /// allowlist never references a tool the tier can't run.
    private func pruneToCapability() {
        let names = Set(permittedTools.map(\.name))
        enabled.formIntersection(names)
    }

    // MARK: Load / build

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let policy = model.toolPolicy(for: item)
        capability = policy.capability
        let names = Set(permittedTools.map(\.name))
        if let allowed = policy.allowed {
            enabled = Set(allowed).intersection(names)
        } else {
            enabled = names   // nil allowlist = every permitted tool is on
        }
    }

    private func buildPolicy() -> ToolPolicy {
        let permitted = Set(permittedTools.map(\.name))
        let on = enabled.intersection(permitted)
        // Full permitted set ⇒ no allowlist (rely on the capability tier alone);
        // otherwise store the explicit subset (including [] for a converse-only lock).
        let allowed: [String]? = (on == permitted) ? nil : on.sorted()
        return ToolPolicy(capability: capability, allowed: allowed)
    }
}
