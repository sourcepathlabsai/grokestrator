import SwiftUI
import GrokestratorCore

/// Left sidebar: instances grouped by server (design 02) — "This Mac" first,
/// then each connected remote server with its instances.
struct SidebarView: View {
    @Bindable var model: GrokestratorModel
    @State private var showingAdd = false
    @State private var showingAddRemote = false
    @State private var showingArchived = false
    /// Live Connection awaiting a permanent-delete confirmation (nil ⇒ none).
    @State private var pendingDelete: InstanceItem?

    var body: some View {
        VStack(spacing: 0) {
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
                                        // Archive + permanent delete are only meaningful for local
                                        // Connections — remote instances are managed by their server.
                                        if instance.serverID == nil {
                                            Button("Archive") { model.archive(instance) }
                                            Divider()
                                            Button("Delete…", role: .destructive) { pendingDelete = instance }
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
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            archivedFooter
        }
        .navigationTitle("Grokestrator")
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
        .sheet(isPresented: $showingArchived) { ArchivedConnectionsView(model: model) }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")” permanently?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) {
                model.delete(item)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This stops the connection and erases its config and entire chat history. This can't be undone. To keep it recoverable, Archive instead.")
        }
    }

    /// Footer button revealing the archived Connections sheet. Hidden when nothing
    /// is archived to keep the sidebar quiet on first use.
    @ViewBuilder
    private var archivedFooter: some View {
        let count = model.archivedConnections.count
        if count > 0 {
            Divider().overlay(Theme.border)
            Button { showingArchived = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "archivebox").font(.system(size: 11))
                    Text("Archived (\(count))").font(Theme.body(11))
                    Spacer()
                }
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
