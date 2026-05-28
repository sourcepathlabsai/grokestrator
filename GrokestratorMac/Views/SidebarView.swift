import SwiftUI
import GrokestratorCore

/// Left sidebar: instances grouped by server (design 02) — "This Mac" first,
/// then each connected remote server with its instances.
struct SidebarView: View {
    @Bindable var model: GrokestratorModel
    @State private var showingAdd = false
    @State private var showingAddRemote = false

    var body: some View {
        List(selection: $model.selectedInstanceID) {
            ForEach(model.sidebarGroups) { group in
                Section {
                    if group.instances.isEmpty {
                        Text(group.isRemote ? (group.isConnected ? "No remote instances" : "Disconnected")
                                            : "No connections yet")
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(group.instances) { instance in
                            InstanceRow(instance: instance)
                                .tag(instance.id)
                                .contextMenu {
                                    if instance.status == .running || instance.status == .starting {
                                        Button("Stop") { model.stop(instance) }
                                    }
                                }
                        }
                    }
                } header: {
                    SectionHeader(group: group, onRemove: group.isRemote ? {
                        if let link = model.remoteLinks.first(where: { $0.id == group.id }) {
                            model.removeRemoteServer(link)
                        }
                    } : nil)
                }
            }
        }
        .navigationTitle("Grokestrator")
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.bgDeep)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button { showingAdd = true } label: { Label("Add Local Connection…", systemImage: "macbook") }
                    Button { showingAddRemote = true } label: { Label("Add Remote Server…", systemImage: "network") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddConnectionView(model: model) }
        .sheet(isPresented: $showingAddRemote) { AddRemoteServerView(model: model) }
    }
}

/// A sidebar section header: title + a status dot for remote servers, plus a
/// context-menu "Remove" for remote groups.
private struct SectionHeader: View {
    let group: SidebarServerGroup
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if group.isRemote {
                Circle()
                    .fill(group.isConnected ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
            }
            Text(group.title)
                .font(Theme.display(11, .semibold))
                .foregroundStyle(Theme.textFaint)
                .textCase(.uppercase)
        }
        .contextMenu {
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Server", systemImage: "trash")
                }
            }
        }
    }
}

/// A single connection row: status indicator + name.
private struct InstanceRow: View {
    let instance: InstanceItem

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(instance.name)
                .font(Theme.body(13, .medium))
                .foregroundStyle(Theme.textBody)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
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
