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
    /// Remote server config being edited (nil ⇒ none).
    @State private var editingServer: RemoteServerConfig?
    /// Remote server awaiting a remove confirmation (nil ⇒ none).
    @State private var pendingServerRemoval: RemoteServerLink?
    /// Orchestrator nodes the user has collapsed. Absent ⇒ expanded (the default),
    /// so a freshly-designated orchestrator shows its children right away.
    @State private var collapsedNodes: Set<UUID> = []
    /// The Connection we're adding a child agent under (nil ⇒ not adding).
    @State private var addingChildFor: InstanceItem?
    /// The Connection whose role/system prompt we're editing (nil ⇒ not editing).
    @State private var editingRoleFor: InstanceItem?
    /// The Connection whose brain binding we're editing (nil ⇒ not editing).
    @State private var editingBrainFor: InstanceItem?
    /// The Connection whose tool/capability policy we're editing (nil ⇒ not editing).
    @State private var editingToolsFor: InstanceItem?
    /// The Connection whose MCP-server access we're editing (nil ⇒ not editing).
    @State private var editingMCPFor: InstanceItem?

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
                            groupBody(group)
                        }
                    } header: {
                        header(for: group)
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
        .sheet(item: $addingChildFor) { parent in AddConnectionView(model: model, parent: parent) }
        .sheet(item: $editingRoleFor) { item in EditRoleView(model: model, item: item) }
        .sheet(item: $editingBrainFor) { item in EditBrainView(model: model, item: item) }
        .sheet(item: $editingToolsFor) { item in EditToolPolicyView(model: model, item: item) }
        .sheet(item: $editingMCPFor) { item in EditMCPAccessView(model: model, item: item) }
        .sheet(isPresented: $showingAddRemote) { AddRemoteServerView(model: model) }
        .sheet(item: $editingServer) { config in AddRemoteServerView(model: model, editing: config) }
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
        .confirmationDialog(
            "Remove “\(pendingServerRemoval?.config.name ?? "")”?",
            isPresented: Binding(get: { pendingServerRemoval != nil },
                                 set: { if !$0 { pendingServerRemoval = nil } }),
            presenting: pendingServerRemoval
        ) { link in
            Button("Remove Server", role: .destructive) {
                model.removeRemoteServer(link)
                pendingServerRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingServerRemoval = nil }
        } message: { _ in
            Text("Removes this server from this device. The Mac and its grok sessions are unaffected.")
        }
    }

    /// Builds a section header for one server group, wiring the remote-only
    /// reconnect / edit / remove actions to the matching link. Extracted from the
    /// `header:` closure because the inline ternary-closures defeated the
    /// SwiftUI type-checker.
    @ViewBuilder
    private func header(for group: SidebarServerGroup) -> some View {
        let link = group.isRemote ? model.remoteLinks.first(where: { $0.id == group.id }) : nil
        SectionHeader(
            group: group,
            pathLabel: group.isRemote ? remotePathLabel(group.id) : nil,
            onReconnect: (group.isDown && link != nil) ? { if let link { model.reconnectRemoteServer(link) } } : nil,
            onEdit: link != nil ? { if let link { editingServer = link.config } } : nil,
            onRemove: link != nil ? { if let link { pendingServerRemoval = link } } : nil
        )
    }

    // MARK: - Orchestration tree rendering (one level of nesting)

    /// Renders a group's instances as a one-level tree: orchestrators that have
    /// children become `DisclosureGroup`s; everything else (roots and orphans
    /// whose parent isn't an orchestrator) renders flat. Selection + context menu
    /// behave identically for parent and child rows.
    @ViewBuilder
    private func groupBody(_ group: SidebarServerGroup) -> some View {
        let orchestratorIDs = Set(group.instances.filter { $0.role == .orchestrator }.map(\.id))
        let childrenByParent = Dictionary(grouping: group.instances.filter {
            guard let p = $0.parentID else { return false }
            return orchestratorIDs.contains(p)
        }, by: { $0.parentID! })
        let roots = group.instances.filter { item in
            guard let p = item.parentID else { return true }   // no parent ⇒ root
            return !orchestratorIDs.contains(p)                 // parent isn't a live orchestrator ⇒ surface as root
        }

        ForEach(roots) { root in
            if root.role == .orchestrator, let kids = childrenByParent[root.id], !kids.isEmpty {
                DisclosureGroup(isExpanded: expansionBinding(root.id)) {
                    ForEach(kids) { kid in instanceRow(kid, in: group) }
                } label: {
                    instanceRow(root, in: group)
                }
            } else {
                instanceRow(root, in: group)
            }
        }
    }

    /// One selectable row + its context menu, shared by parent and child rows.
    @ViewBuilder
    private func instanceRow(_ instance: InstanceItem, in group: SidebarServerGroup) -> some View {
        InstanceRow(instance: instance, serverDown: group.isDown)
            .tag(instance.id)
            .contextMenu { rowMenu(instance) }
    }

    /// The per-row context menu, including the orchestration-tree controls for
    /// local Connections (mark orchestrator / agent, set parent).
    @ViewBuilder
    private func rowMenu(_ instance: InstanceItem) -> some View {
        if instance.status == .running || instance.status == .starting {
            Button("Stop") { model.stop(instance) }
        }
        // Role + parent + archive/delete are only meaningful for local Connections
        // — remote instances (and their tree) are managed by their own server.
        if instance.serverID == nil {
            Divider()
            Button("Edit Role…") { editingRoleFor = instance }
            Button("Edit Brain…") { editingBrainFor = instance }
            Button("Edit Tools…") { editingToolsFor = instance }
            Button("MCP Access…") { editingMCPFor = instance }
            // Create a child agent under this Connection — promotes it to
            // orchestrator automatically (see GrokestratorModel.addRealConnection).
            Button("Add Child Agent…") { addingChildFor = instance }
            if instance.role == .orchestrator {
                Button("Make Agent") { model.setRole(.agent, for: instance) }
            } else {
                Button("Make Orchestrator") { model.setRole(.orchestrator, for: instance) }
            }
            // An agent can be parented under an orchestrator (one level for now).
            if instance.role == .agent {
                let parents = model.localOrchestrators.filter { $0.id != instance.id }
                Menu("Parent") {
                    Button(instance.parentID == nil ? "✓ None" : "None") {
                        model.setParent(nil, for: instance)
                    }
                    if !parents.isEmpty { Divider() }
                    ForEach(parents) { orch in
                        Button(instance.parentID == orch.id ? "✓ \(orch.name)" : orch.name) {
                            model.setParent(orch.id, for: instance)
                        }
                    }
                }
            }
            Divider()
            Button("Archive") { model.archive(instance) }
            Button("Delete…", role: .destructive) { pendingDelete = instance }
        }
    }

    private func expansionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedNodes.contains(id) },
            set: { open in
                if open { collapsedNodes.remove(id) } else { collapsedNodes.insert(id) }
            }
        )
    }

    /// "· LAN" / "· Tailscale" / "· connecting…" for a remote server group, so
    /// you can see which path is active at a glance.
    private func remotePathLabel(_ id: UUID) -> String? {
        guard let link = model.remoteLinks.first(where: { $0.id == id }) else { return nil }
        switch link.state {
        case .connected:    return link.activePath.map { "· \($0)" } ?? "· connected"
        case .connecting:   return "· connecting…"
        case .failed:       return "· failed"
        case .disconnected: return "· offline"
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
    var pathLabel: String? = nil
    var onReconnect: (() -> Void)? = nil
    let onEdit: (() -> Void)?
    let onRemove: (() -> Void)?

    /// Green = connected, yellow = connecting, red = failed, grey = offline.
    private var dotColor: Color {
        switch group.state {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .disconnected: return .gray
        }
    }

    /// LAN path stands out in accent; a failed/offline state reads red.
    private func labelColor(_ label: String) -> Color {
        if group.isDown { return Color.red.opacity(0.9) }
        return label.contains("LAN") ? Theme.accent : Theme.textFaint
    }

    var body: some View {
        HStack(spacing: 6) {
            if group.isRemote {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(group.title)
                .font(Theme.display(11, .semibold))
                .foregroundStyle(group.isDown ? Color.red.opacity(0.9) : Theme.textFaint)
                .textCase(.uppercase)
            if let pathLabel {
                Text(pathLabel)
                    .font(Theme.body(9))
                    .foregroundStyle(labelColor(pathLabel))
            }
            if onReconnect != nil || onEdit != nil || onRemove != nil {
                Spacer(minLength: 4)
                if let onReconnect {
                    Button(action: onReconnect) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .help("Reconnect to server")
                }
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textFaint)
                    .help("Edit server")
                }
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textFaint)
                    .help("Remove server")
                }
            }
        }
        .contextMenu {
            if let onEdit {
                Button(action: onEdit) { Label("Edit Server…", systemImage: "pencil") }
            }
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
    /// When the parent server is unreachable, the session can't be driven — show
    /// its dot red regardless of the last-known instance status. It recovers
    /// automatically when the server reconnects (no per-session reconnect).
    var serverDown: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            if instance.role == .orchestrator {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .help("Orchestrator")
                    .accessibilityLabel("Orchestrator")
            }
            Text(instance.name)
                .font(Theme.body(13, .medium))
                .foregroundStyle(serverDown ? Theme.textFaint : Theme.textBody)
                .lineLimit(1)
            Spacer(minLength: 4)
            // "Needs you" badge: this Connection has a pending permission/question
            // waiting for an answer — visible even while you're in another one.
            if instance.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
                    .help("Waiting for your answer")
                    .accessibilityLabel("Needs your attention")
            } else if instance.isBusy {
                // Pulsing cyan dots: this agent is actively working a turn — shown
                // even when the Connection isn't the one on screen, so you can see
                // at a glance which agents are busy.
                ThinkingIndicator(status: "", compact: true)
                    .help("Working…")
                    .accessibilityLabel("Working")
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        if serverDown { return .red }
        switch instance.status {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .crashed, .errored: return .red
        case .stopped: return .secondary
        }
    }
}
