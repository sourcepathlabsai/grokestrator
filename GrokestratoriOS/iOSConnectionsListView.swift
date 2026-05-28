import SwiftUI
import GrokestratorCore

/// Sidebar listing every connected remote server and its shared Connections.
/// Tapping a Connection navigates to `iOSConversationView` (in the detail
/// column on iPad, pushed onto the stack on iPhone).
struct iOSConnectionsListView: View {
    @Bindable var model: iOSAppModel
    @State private var showingAddServer = false

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
                            .fill(link.state == .connected ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(link.config.name)
                            .font(Theme.display(11, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .textCase(.uppercase)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { model.removeRemoteServer(link) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
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
}

private struct ConnectionRow: View {
    let instance: InstanceItem

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(instance.name).font(Theme.body(15, .medium)).foregroundStyle(Theme.textBody)
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
