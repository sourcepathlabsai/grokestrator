import SwiftUI
import GrokestratorCore

/// App Settings: the server toggle, plus the **host tier map** (Brains) — the
/// machine-local `Tier → AgentBackend` resolution that `dynamic` Nodes use. Off by
/// default; enabling the server opens the listener on the chosen port. Tailscale
/// handles encryption / access.
struct SettingsView: View {
    @Bindable var model: GrokestratorModel

    /// Working copy of the host tier map; committed via `model.setHostTierMap`.
    @State private var tierMap: HostTierMap = .default
    @State private var tierMapLoaded = false
    /// Bumped on Revert to force the per-tier `BackendEditor`s to re-decode.
    @State private var revertTick = 0

    var body: some View {
        TabView {
            serverTab
                .tabItem { Label("Server", systemImage: "network") }
                .frame(minWidth: 520, minHeight: 320)
            brainsTab
                .tabItem { Label("Brains", systemImage: "brain") }
                .frame(minWidth: 520, minHeight: 320)
        }
        .onAppear {
            guard !tierMapLoaded else { return }
            tierMapLoaded = true
            tierMap = model.hostTierMap
        }
    }

    // MARK: Brains (host tier map)

    private var brainsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Map each capability tier to a brain. A Node set to **Dynamic** runs on its tier's backend here; **Pinned** Nodes are unaffected. Per-task routing across tiers activates in a later phase — for now a dynamic Node uses its default tier.")
                    .font(Theme.body(11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Tier.allCases, id: \.self) { tier in
                    GroupBox {
                        BackendEditor(backend: tierBinding(tier))
                            .id("\(tier.rawValue)-\(revertTick)")
                            .padding(6)
                    } label: {
                        Text(tier.rawValue.capitalized).font(Theme.display(12, .semibold))
                    }
                }

                HStack {
                    Spacer()
                    Button("Revert") { tierMap = model.hostTierMap; revertTick += 1 }
                        .disabled(tierMap == model.hostTierMap)
                    Button("Save") { model.setHostTierMap(tierMap) }
                        .buttonStyle(.borderedProminent)
                        .disabled(tierMap == model.hostTierMap)
                }
            }
            .padding()
        }
    }

    private func tierBinding(_ tier: Tier) -> Binding<AgentBackend> {
        Binding(
            get: { tierMap.entries[tier] ?? .grokACP },
            set: { tierMap.entries[tier] = $0 }
        )
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
