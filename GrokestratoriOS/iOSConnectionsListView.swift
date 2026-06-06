import SwiftUI
import GrokestratorCore

/// Sidebar listing every connected remote server and its shared Connections.
/// Tapping a Connection navigates to `iOSConversationView` (in the detail
/// column on iPad, pushed onto the stack on iPhone).
struct iOSConnectionsListView: View {
    @Bindable var model: iOSAppModel
    @State private var showingAddServer = false
    /// Server awaiting a remove confirmation (nil ⇒ none).
    @State private var pendingRemoval: RemoteServerLink?
    /// Server config being edited (nil ⇒ none).
    @State private var editingServer: RemoteServerConfig?

    var body: some View {
        List(selection: $model.selectedInstanceID) {
            ForEach(model.remoteLinks) { link in
                Section {
                    let connections = model.instances.filter { $0.serverID == link.id }
                    if connections.isEmpty {
                        Text(link.state == .connected ? "No shared Connections" : statusLabel(link.state))
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textFaint)
                    } else {
                        ForEach(connections) { instance in
                            ConnectionRow(instance: instance)
                                .tag(instance.id)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dotColor(link.state))
                            .frame(width: 6, height: 6)
                        Text(link.config.name)
                            .font(Theme.display(11, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .textCase(.uppercase)
                        Text(pathLabel(link))
                            .font(Theme.body(9))
                            .foregroundStyle(link.activePath == "LAN" ? Theme.accent : Theme.textFaint)
                            .textCase(.lowercase)
                        Spacer()
                        // Always-visible edit + remove. (Swipe-to-delete can't be
                        // used here: the rows are Connections under the server, and
                        // a never-connected server has none to swipe.)
                        Button { editingServer = link.config } label: {
                            Image(systemName: "pencil").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textFaint)
                        Button(role: .destructive) { pendingRemoval = link } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.config.name ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { link in
            Button("Remove Server", role: .destructive) {
                model.removeRemoteServer(link)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("Removes this server from this device. The Mac and its grok sessions are unaffected.")
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgDeep)
        .navigationTitle("Grokestrator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddServer = true } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddServer) {
            iOSAddRemoteServerView(model: model)
        }
        .sheet(item: $editingServer) { config in
            iOSAddRemoteServerView(model: model, editing: config)
        }
        .overlay {
            if model.remoteLinks.isEmpty {
                ContentUnavailableView {
                    Label("No servers yet", systemImage: "network")
                } description: {
                    Text("Tap + to add a Grokestrator server reachable over Tailscale.")
                } actions: {
                    Button("Add Server") { showingAddServer = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func statusLabel(_ s: RemoteServerLink.LinkState) -> String {
        switch s {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .failed(let r): return "Failed: \(r)"
        }
    }

    /// Short path/state label shown next to a server name so you can tell at a
    /// glance whether you're on the fast LAN path or Tailscale.
    private func pathLabel(_ link: RemoteServerLink) -> String {
        switch link.state {
        case .connected:    return link.activePath.map { "· \($0)" } ?? "· connected"
        case .connecting:   return "· connecting…"
        case .disconnected: return "· offline"
        case .failed:       return "· failed"
        }
    }

    private func dotColor(_ s: RemoteServerLink.LinkState) -> Color {
        switch s {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .gray
        }
    }
}

private struct ConnectionRow: View {
    let instance: InstanceItem

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(instance.name).font(Theme.body(15, .medium)).foregroundStyle(Theme.textBody)
            Spacer(minLength: 4)
            if instance.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Needs your attention")
            } else if instance.isBusy {
                ThinkingIndicator(status: "", compact: true)
                    .accessibilityLabel("Working")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .crashed, .errored: return .red
        case .stopped: return .secondary
        }
    }
}
