import SwiftUI
import GrokestratorCore

/// App Settings: the server toggle, plus **Brains** — the host-local brain catalog
/// (named provider+model brains) and the `Tier → BrainRef` map that `dynamic` Nodes
/// resolve through. Off by default; enabling the server opens the listener on the
/// chosen port. Tailscale handles encryption / access.
struct SettingsView: View {
    @Bindable var model: GrokestratorModel

    /// Working copy of the host tier map; committed via `model.setHostTierMap`.
    @State private var tierMap: HostTierMap = .default
    @State private var tierMapLoaded = false

    @State private var addingProfile = false
    @State private var editingProfile: BrainProfile?

    var body: some View {
        TabView {
            serverTab
                .tabItem { Label("Server", systemImage: "network") }
                .frame(minWidth: 520, minHeight: 320)
            brainsTab
                .tabItem { Label("Brains", systemImage: "brain") }
                .frame(minWidth: 560, minHeight: 420)
        }
        .onAppear {
            guard !tierMapLoaded else { return }
            tierMapLoaded = true
            tierMap = model.hostTierMap
        }
        .sheet(isPresented: $addingProfile) { BrainProfileEditorView(model: model) }
        .sheet(item: $editingProfile) { p in BrainProfileEditorView(model: model, existing: p) }
    }

    // MARK: Brains (catalog + tier map)

    private var brainsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                catalogSection
                Divider()
                tierMapSection
            }
            .padding()
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Brain Catalog").font(Theme.display(12, .semibold))
                Spacer()
                Button { addingProfile = true } label: { Label("Add Brain", systemImage: "plus") }
            }
            Text("Named brains (provider + model) you point Nodes and tiers at. Add several per service to pick the model fit for each task. Keys resolve host-locally; nothing here is a secret.")
                .font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if model.brainCatalog.profiles.isEmpty {
                Text("No brains yet. **Add Brain** to create one (Groq, Cerebras, xAI, Gemini, local…).")
                    .font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.brainCatalog.profiles) { profile in
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(Theme.body(12, .semibold))
                                Text(backendSummary(profile.backend))
                                    .font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Button("Edit") { editingProfile = profile }
                            Button(role: .destructive) { model.removeBrainProfile(profile.id) } label: {
                                Image(systemName: "trash")
                            }
                            .help("Remove this brain")
                        }
                    }
                }
            }
        }
    }

    private var tierMapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tier Map").font(Theme.display(12, .semibold))
            Text("Map each capability tier to a brain. A **Dynamic** Node resolves its tier here; **grok** and brains pinned directly on a Node are unaffected. Per-task routing across tiers activates in a later phase — for now a dynamic Node uses its default tier.")
                .font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Tier.allCases, id: \.self) { tier in
                HStack {
                    Text(tier.rawValue.capitalized).frame(width: 90, alignment: .leading)
                    Picker("", selection: tierRefBinding(tier)) {
                        Text("grok").tag(BrainRef.grok)
                        ForEach(model.brainCatalog.profiles) { p in
                            Text(p.name).tag(BrainRef.profile(p.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Revert") { tierMap = model.hostTierMap }
                    .disabled(tierMap == model.hostTierMap)
                Button("Save") { model.setHostTierMap(tierMap) }
                    .buttonStyle(.borderedProminent)
                    .disabled(tierMap == model.hostTierMap)
            }
        }
    }

    private func tierRefBinding(_ tier: Tier) -> Binding<BrainRef> {
        Binding(
            get: { tierMap.entries[tier] ?? .grok },
            set: { tierMap.entries[tier] = $0 }
        )
    }

    /// One-line summary of a brain's backend for the catalog list.
    private func backendSummary(_ backend: AgentBackend) -> String {
        switch backend {
        case .grokACP: return "grok"
        case .onboard(let path): return "onboard · \(path)"
        case .gemini(let model, _): return "gemini · \(model)"
        case .openAICompatible(let url, let model, let ref):
            return "\(model)  @ \(url)" + (ref.map { "  · key \($0)" } ?? "")
        }
    }

    private var serverTab: some View {
        Form {
            Section {
                Toggle("Run server on this Mac", isOn: $model.serverEnabled)
                Text("Lets other Grokestrator clients (Mac or iOS) drive this Mac's grok instances over Tailscale. Off by default. Tailscale is the trust boundary — no extra authentication is enforced at this layer.")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.textMuted)
            } header: {
                Text("Remote Access").font(Theme.display(12, .semibold))
            }

            Section {
                Stepper(value: $model.serverPort, in: 1024...65535) {
                    HStack {
                        Text("Port")
                        Spacer()
                        Text("\(model.serverPort)").font(Theme.mono(12)).foregroundStyle(Theme.textBody)
                    }
                }
                .disabled(!model.serverEnabled)

                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                }
            } header: {
                Text("Listener").font(Theme.display(12, .semibold))
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        // The server's state is on the actor; we display the user's intent here
        // and rely on the model's didSet to apply it. A live status indicator is
        // a small follow-up.
        model.serverEnabled ? "Listening on port \(model.serverPort)" : "Stopped"
    }
    private var statusColor: Color { model.serverEnabled ? .green : .secondary }
}
