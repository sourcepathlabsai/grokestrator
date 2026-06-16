import SwiftUI
import GrokestratorCore

/// Sheet to choose which host MCP servers a Node may reach — its **grant** over the
/// registry. "All" (the default) tracks the registry as it grows; otherwise an
/// explicit subset. grok Nodes get the granted set injected into `session/new`;
/// API-brain Nodes reach them via the in-app MCP client. Saving restarts the Node.
struct EditMCPAccessView: View {
    @Bindable var model: GrokestratorModel
    let item: InstanceItem
    @Environment(\.dismiss) private var dismiss

    /// nil ⇒ all servers (unrestricted); otherwise the explicit granted set.
    @State private var grantAll: Bool = true
    @State private var granted: Set<UUID> = []
    @State private var loaded = false
    @State private var addingServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").foregroundStyle(.tint)
                Text("MCP Access — \(item.name)").font(.headline)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow all MCP servers (including ones added later)", isOn: $grantAll)

                if model.mcpRegistry.servers.isEmpty {
                    HStack(spacing: 8) {
                        Text("No MCP servers configured yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { addingServer = true } label: { Label("Add Server…", systemImage: "plus") }
                            .font(.caption)
                    }
                } else {
                    Text("Servers this Node may use:").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.mcpRegistry.servers) { server in
                        Toggle(isOn: Binding(
                            get: { grantAll || granted.contains(server.id) },
                            set: { on in if on { granted.insert(server.id) } else { granted.remove(server.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                Text(summary(server.transport)).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(grantAll)
                    }
                }
                Text("Manage the server list in Settings ▸ MCP.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()

            Divider()
            HStack {
                if item.status == .running || item.status == .starting {
                    Label("Saving restarts this Node", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setMCPGrant(grantAll ? nil : Array(granted), for: item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear { loadOnce() }
        .sheet(isPresented: $addingServer) { MCPServerEditorView(model: model) }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        if let ids = model.mcpGrant(for: item) {
            grantAll = false
            granted = Set(ids)
        } else {
            grantAll = true
            // Seed the explicit set with everything, so unchecking "all" starts from
            // the current full grant rather than empty.
            granted = Set(model.mcpRegistry.servers.map(\.id))
        }
    }

    private func summary(_ transport: MCPTransport) -> String {
        switch transport {
        case .stdio(let command, let args, _): return ([command] + args).joined(separator: " ")
        case .http(let url, _): return url
        }
    }
}
