import Foundation
import Observation
import GrokestratorCore

// `InstanceItem` moved to GrokestratorShared/Model/InstanceItem.swift so iOS
// can use the same type.

/// A sidebar grouping — "This Mac" first, then each remote server with its
/// instances. The view layer reads these and renders one `Section` per group.
struct SidebarServerGroup: Identifiable, Sendable {
    let id: UUID
    let title: String
    let isRemote: Bool
    /// Full link state so the sidebar can colour the dot (green/yellow/red/grey)
    /// and decide whether to offer a Reconnect button. `.connected` for local.
    let state: RemoteServerLink.LinkState
    let instances: [InstanceItem]

    var isConnected: Bool { state == .connected }
    /// A remote server that is not currently connected → its sessions should read
    /// as unreachable (red dots) and the header offers a manual reconnect.
    var isDown: Bool { isRemote && state != .connected && state != .connecting }
}

/// Root application state for the Mac app.
///
/// Owns the local instance list, the remote-server links, the local-server
/// listener (for serving other Grokestrator clients over Tailscale), and the
/// current selection.
@MainActor
@Observable
final class GrokestratorModel {
    /// Local + remote instances (mixed). Use `sidebarGroups` to partition.
    var instances: [InstanceItem]
    var selectedInstanceID: InstanceItem.ID?

    /// Persistent registry of every local Connection — active *and* archived.
    /// Source of truth for the local Mac (GKSS); the `instances` array is the
    /// UI projection of the non-archived entries here. Loaded from
    /// `connections.json` on boot, saved on every mutation.
    var connections: [ManagedConnection]

    /// The local Grok Build black box (drives instances running on *this* Mac).
    let manager = GrokBuildManager()

    /// Listener that lets other Grokestrator clients drive `manager`'s instances
    /// over Tailscale. Off by default; enabled from Settings.
    let server: MacGrokestratorServer

    /// In-app Orchestration MCP server (loopback) that grok Nodes connect to so an
    /// orchestrator can `delegate` to its children. Host-local and independent of
    /// the remote-serving toggle — it runs whenever the app is up. See
    /// `design/11-orchestration-platform.md`. Phase 1b: the spine + a stubbed
    /// `delegate`; Phase 1c installs the real router via `setDelegateHandler`.
    let orchestrationMCP = OrchestrationMCPServer()

    /// Active + recent delegation runs for the sidebar Run view (#134).
    let delegationRuns = DelegationRunStore()

    /// Scheduled triggers + task.report ledger (#135).
    let orchestrationTriggers = OrchestrationTriggerStore()

    /// Embedded workflow DB for schema-validated task exchange (#133).
    let orchestrationDB = OrchestrationDatabaseImpl(
        fileURL: ConnectionStore.supportDir.appendingPathComponent("orchestration.db")
    )

    /// Persistent remote-server configs + their live connection state.
    var remoteLinks: [RemoteServerLink]

    /// Host-local `Tier → BrainRef` map (machine config; gitignored). A `dynamic`
    /// Node resolves its tier through this when it (re)starts. Edited in
    /// Settings ▸ Brains. See `design/12-model-agnostic-runtime.md` Phase F.
    var hostTierMap: HostTierMap = ConnectionStore.loadTierMap()

    /// Host-local library of named brains (provider + model + key name). Nodes and
    /// the tier map reference these by id. Curated in Settings ▸ Brains.
    var brainCatalog: BrainCatalog = ConnectionStore.loadBrainCatalog()

    /// Host-local MCP server registry (machine config). grok Nodes get their granted
    /// subset injected into `session/new`; API brains reach them via the in-app MCP
    /// client. Curated in Settings ▸ MCP. See `design/12` Phase C (MCP bridge).
    var mcpRegistry: MCPRegistry = ConnectionStore.loadMCPRegistry()

    /// User-authored fleet team templates (built-ins live in code).
    var customTeamTemplates: [TeamTemplate] = ConnectionStore.loadTeamTemplates().custom

    /// Built-in + custom fleet templates for Create Team and Settings.
    var fleetTeamTemplates: [TeamTemplate] {
        TeamTemplate.builtins + customTeamTemplates.filter(\.requiresOrchestratedFleet)
    }

    // MARK: - Server settings (mirrored to UserDefaults)

    private static let serverEnabledKey = "grokestrator.server.enabled.v1"
    private static let serverPortKey = "grokestrator.server.port.v1"

    var serverEnabled: Bool {
        didSet {
            UserDefaults.standard.set(serverEnabled, forKey: Self.serverEnabledKey)
            applyServerToggle()
        }
    }
    var serverPort: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(serverPort), forKey: Self.serverPortKey)
            if serverEnabled { applyServerToggle() }
        }
    }

    init(instances: [InstanceItem] = [], connections: [ManagedConnection] = []) {
        self.instances = instances
        self.connections = connections
        self.selectedInstanceID = instances.first?.id
        self.server = MacGrokestratorServer(manager: manager)
        let remoteConfigs = RemoteServerStore.load()
        self.remoteLinks = remoteConfigs.map { RemoteServerLink(config: $0) }
        self.serverEnabled = UserDefaults.standard.bool(forKey: Self.serverEnabledKey)
        let storedPort = UserDefaults.standard.integer(forKey: Self.serverPortKey)
        self.serverPort = storedPort == 0 ? 7847 : UInt16(storedPort)
        // First-run: scaffold the host-local secrets file so it exists (with a
        // commented template) and the in-app brain editors can write keys into it.
        Secrets.ensureTemplateExists()
        // Start the host-local Orchestration MCP server (loopback). Runs
        // regardless of the remote-serving toggle so launched Nodes can delegate.
        let orchestrationMCP = self.orchestrationMCP
        let manager = self.manager
        let delegationRuns = self.delegationRuns
        let orchestrationDB = self.orchestrationDB
        Task {
            do {
                try await orchestrationMCP.start(port: OrchestrationMCPServer.defaultPort)
                await orchestrationMCP.setDatabase(orchestrationDB)
                await manager.setDelegationRunCallback { update in
                    Task { @MainActor in delegationRuns.apply(update) }
                }
                // Install the real router (Phase 1c): delegate(child, task) sends
                // the task to the named child Node and returns its final answer.
                await orchestrationMCP.setDelegateHandler { caller, child, task, timeout in
                    await manager.delegate(callerID: caller, toChildNamed: child, task: task,
                                           timeout: timeout ?? 120)
                }
                await orchestrationMCP.setTaskReportHandler { caller, status, result in
                    await MainActor.run {
                        self.handleTaskReport(callerID: caller, status: status, result: result)
                    }
                }
                await orchestrationMCP.setNodeConfigureHandler { caller, child, policyJSON in
                    await self.handleNodeConfigure(callerID: caller, childName: child, policyJSON: policyJSON)
                }
                await orchestrationMCP.setTriggerScheduleHandler { caller, child, when, task in
                    await MainActor.run {
                        self.handleTriggerSchedule(callerID: caller, childName: child, when: when, task: task)
                    }
                }
                await orchestrationMCP.setTriggerFireHandler { caller, event, payload in
                    await self.handleTriggerFire(callerID: caller, event: event, payload: payload)
                }
                OrchestrationMCPServer.isActive = true
                NSLog("[orchestration] MCP server listening on :\(OrchestrationMCPServer.defaultPort)")
            } catch {
                // Non-fatal: sessions just won't advertise the delegate tool.
                NSLog("[orchestration] MCP server failed to start: \(error)")
            }
        }
        // Start listener immediately if the user had it enabled last run; also
        // kick off auto-connect for any saved remote servers.
        if serverEnabled { applyServerToggle() }
        for link in remoteLinks { Task { await self.connectAndAttach(link) } }
    }

    /// Default app state: load the persisted Connection registry and build UI
    /// items for the non-archived entries. Connections with `autoRestart == true`
    /// are launched in the background. First run shows an empty sidebar; the
    /// "+" button creates the first real Connection.
    convenience init() {
        // Drop any legacy mock entries from an older build's first-run seed
        // (`command == "/mock/grok"`). MockConversationDriver is gone; trying
        // to launch a fake binary would just fail.
        let registry = ConnectionStore.load().filter { $0.command != "/mock/grok" }
        // If we removed something, rewrite so we don't keep filtering forever.
        if registry.count != ConnectionStore.load().count {
            ConnectionStore.save(registry)
        }

        let seededInstances: [InstanceItem] = registry
            .filter { !$0.archived }
            .map { conn in
                InstanceItem(
                    id: conn.id, name: conn.name, status: .stopped,
                    driver: LiveConversationDriver(manager: GrokBuildManager(), instanceID: conn.id),   // re-bound below
                    role: conn.role, parentID: conn.parentID, rolePrompt: conn.rolePrompt
                )
            }
        self.init(instances: seededInstances, connections: registry)

        // Re-bind LiveConversationDrivers to the actual manager (the items
        // above used a throwaway manager because `self` wasn't ready yet).
        for (idx, item) in instances.enumerated() {
            let rebound = InstanceItem(
                id: item.id, name: item.name, status: .stopped,
                driver: LiveConversationDriver(manager: manager, instanceID: item.id),
                role: item.role, parentID: item.parentID, rolePrompt: item.rolePrompt
            )
            instances[idx] = rebound
            // Subscribe now so the host reflects remote-driven turns even before
            // this Connection is ever opened on the host.
            rebound.conversation.startSubscription()
        }
        if selectedInstanceID == nil { selectedInstanceID = instances.first?.id }

        // Migrate any pre-catalog inline API brains into catalog profiles (so old
        // configs reference the catalog like everything else). No-op after the
        // first run that needed it.
        migrateBrainsIfNeeded()

        // Push saved role prompts into the manager so each Node's conversation
        // primes with its role. Race-free: setRolePrompt and conversation(for:)
        // are both serialized on the manager actor, so whichever runs first, the
        // conversation ends up with the role prompt (see GrokBuildManager).
        let mgr = manager
        let withRoles = registry.filter { !$0.archived && !($0.rolePrompt ?? "").isEmpty }
        if !withRoles.isEmpty {
            Task { for c in withRoles { await mgr.setRolePrompt(for: c.id, c.rolePrompt) } }
        }

        // Auto-launch every non-archived Connection with autoRestart == true.
        for conn in registry where !conn.archived && conn.autoRestart {
            Task { [weak self] in await self?.launchConnection(conn) }
        }
    }

    var selectedInstance: InstanceItem? {
        guard let id = selectedInstanceID else { return nil }
        return instances.first { $0.id == id }
    }

    /// Sidebar grouping: "This Mac" with all local instances, then one section
    /// per remote server with its instances.
    var sidebarGroups: [SidebarServerGroup] {
        let localGroup = SidebarServerGroup(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "This Mac",
            isRemote: false,
            state: .connected,
            instances: instances.filter { $0.serverID == nil }
        )
        let remoteGroups = remoteLinks.map { link in
            SidebarServerGroup(
                id: link.id,
                title: link.config.name,
                isRemote: true,
                state: link.state,
                instances: instances.filter { $0.serverID == link.id }
            )
        }
        return [localGroup] + remoteGroups
    }

    /// How many Connections are currently waiting on the user (pending
    /// permission/question). Drives the Dock badge / global "needs you" count.
    var attentionCount: Int {
        instances.filter(\.needsAttention).count
    }

    // MARK: - Local Connections

    func addRealConnection(name: String, command: String, arguments: [String], workingDirectory: String?,
                           autoRestart: Bool = true, shared: Bool = true,
                           role: NodeRole = .agent, parentID: UUID? = nil, rolePrompt: String? = nil,
                           brain: BrainBinding = .grok) {
        if let parentID, let parent = instances.first(where: { $0.id == parentID }),
           !supportsFleetOrchestration(for: parent) { return }
        let config = ManagedConnection(
            name: name,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            autoRestart: autoRestart,
            shared: shared,
            role: role,
            parentID: parentID,
            rolePrompt: rolePrompt,
            brain: brain
        )
        connections.append(config)
        ConnectionStore.save(connections)

        let item = InstanceItem(
            id: config.id,
            name: name,
            status: .starting,
            driver: LiveConversationDriver(manager: manager, instanceID: config.id),
            role: role, parentID: parentID, rolePrompt: rolePrompt
        )
        instances.append(item)
        selectedInstanceID = item.id
        // Keep the host live for this Connection even when it isn't on-screen,
        // so a turn driven from a remote device streams onto the host too.
        item.conversation.startSubscription()

        // Fleet only: creating a child promotes its parent to orchestrator.
        if let parentID, let parent = instances.first(where: { $0.id == parentID }) {
            guard supportsFleetOrchestration(for: parent) else { return }
            setRole(.orchestrator, for: parent)
        }

        Task { [weak self] in await self?.launchConnection(config, startingItem: item) }
    }

    // MARK: - Team templates (stamp out orchestrator + children)

    /// Create an orchestrator + its child agents from a `TeamTemplate` in one step.
    /// `baseName` is the user-chosen prefix; each member's `nameSuffix` is appended.
    /// All Connections share the same `command`, `arguments`, `workingDirectory`, and
    /// `brain` so the user only configures the runtime once. The orchestrator is
    /// selected after creation.
    func createTeam(from template: TeamTemplate, baseName: String,
                    command: String, arguments: [String], workingDirectory: String?,
                    brain: BrainBinding = .grok) {
        guard !template.members.isEmpty else { return }
        guard !template.requiresOrchestratedFleet || supportsFleetOrchestration(brain: brain) else {
            NSLog("[orchestration] refused team %@ — brain is not orchestrated-fleet", template.id)
            return
        }
        // Create the orchestrator (member[0]).
        let orch = template.members[0]
        let orchName = baseName + orch.nameSuffix
        let orchPolicy: ToolPolicy = template.requiresOrchestratedFleet
            ? .fleetOrchestratorDefault : .unrestricted
        let orchConfig = ManagedConnection(
            name: orchName, command: command, arguments: arguments,
            workingDirectory: workingDirectory,
            autoRestart: true, shared: true,
            role: .orchestrator, parentID: nil,
            rolePrompt: orch.rolePrompt, brain: brain,
            toolPolicy: orchPolicy,
            autoApproval: orch.autoApproval
        )
        connections.append(orchConfig)
        let orchItem = InstanceItem(
            id: orchConfig.id, name: orchName, status: .starting,
            driver: LiveConversationDriver(manager: manager, instanceID: orchConfig.id),
            role: .orchestrator, parentID: nil, rolePrompt: orch.rolePrompt
        )
        instances.append(orchItem)
        orchItem.conversation.startSubscription()

        // Create each child (members[1…]).
        for member in template.members.dropFirst() {
            let childName = baseName + member.nameSuffix
            let childPrompt = template.requiresOrchestratedFleet
                ? member.rolePrompt + TeamTemplate.childEnvelopeSuffix
                : member.rolePrompt
            let childConfig = ManagedConnection(
                name: childName, command: command, arguments: arguments,
                workingDirectory: workingDirectory,
                autoRestart: true, shared: true,
                role: .agent, parentID: orchConfig.id,
                rolePrompt: childPrompt, brain: brain,
                autoApproval: member.autoApproval
            )
            connections.append(childConfig)
            let childItem = InstanceItem(
                id: childConfig.id, name: childName, status: .starting,
                driver: LiveConversationDriver(manager: manager, instanceID: childConfig.id),
                role: .agent, parentID: orchConfig.id, rolePrompt: member.rolePrompt
            )
            instances.append(childItem)
            childItem.conversation.startSubscription()
        }

        ConnectionStore.save(connections)
        selectedInstanceID = orchConfig.id

        // Push role prompts into the manager so each Node primes on first turn.
        let mgr = manager
        let allConfigs = [orchConfig] + connections.filter { $0.parentID == orchConfig.id }
        Task {
            for c in allConfigs where !(c.rolePrompt ?? "").isEmpty {
                await mgr.setRolePrompt(for: c.id, c.rolePrompt)
            }
        }

        // Launch all team members.
        let tolaunch = connections.filter { $0.id == orchConfig.id || $0.parentID == orchConfig.id }
        for config in tolaunch {
            let item = instances.first(where: { $0.id == config.id })
            Task { [weak self] in
                await self?.launchConnection(config, startingItem: item)
            }
        }
    }

    // MARK: - Orchestration tree (role + parent edge)

    /// Local orchestrator Connections on this Mac — the candidates a child can be
    /// parented to. (Orchestration is host-local, so only local Connections.)
    var localOrchestrators: [InstanceItem] {
        instances.filter { $0.serverID == nil && $0.role == .orchestrator }
    }

    /// Set a local Connection's role. Flipping an orchestrator back to `.agent`
    /// leaves any children pointing at it; the sidebar renders an orphaned child
    /// at the top level, so nothing is hidden.
    func setRole(_ role: NodeRole, for item: InstanceItem) {
        if role == .orchestrator && !supportsFleetOrchestration(for: item) { return }
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }) else { return }
        connections[idx].role = role
        ConnectionStore.save(connections)
        item.role = role
        syncTreeMetadataToRemotes(id: item.id, role: role, parentID: item.parentID)
    }

    /// Set (or clear, with `nil`) a local Connection's parent orchestrator. Guards
    /// against self-parenting; deeper cycle checks wait for multi-level trees.
    func setParent(_ parentID: UUID?, for item: InstanceItem) {
        guard item.serverID == nil, parentID != item.id,
              let idx = connections.firstIndex(where: { $0.id == item.id }) else { return }
        if let parentID {
            guard supportsFleetOrchestration(for: item) else { return }
            if let parent = instances.first(where: { $0.id == parentID }),
               !supportsFleetOrchestration(for: parent) { return }
        }
        connections[idx].parentID = parentID
        ConnectionStore.save(connections)
        item.parentID = parentID
        syncTreeMetadataToRemotes(id: item.id, role: item.role, parentID: parentID)
        // Gaining a child makes the parent an orchestrator — so the old two-step
        // (mark orchestrator, then assign parent) collapses into one and never
        // strands a child under a plain agent.
        if let parentID, let parent = instances.first(where: { $0.id == parentID }) {
            setRole(.orchestrator, for: parent)
        }
    }

    func syncTreeMetadataToRemotes(id: UUID, role: NodeRole, parentID: UUID?) {
        let server = self.server
        let manager = self.manager
        Task {
            await manager.updateTreeMetadata(id: id, role: role, parentID: parentID)
            await server.broadcastInstancesIfChanged()
        }
    }

    /// Set (or clear) a local Connection's role/system prompt. Persists it, updates
    /// the live conversation (which re-injects the new role on the next turn — no
    /// restart needed), and broadcasts.
    func setRolePrompt(_ prompt: String?, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        connections[idx].rolePrompt = value
        ConnectionStore.save(connections)
        item.rolePrompt = value
        let manager = self.manager
        let server = self.server
        let id = item.id
        Task {
            await manager.setRolePrompt(for: id, value)
            await server.broadcastInstancesIfChanged()
        }
    }

    /// The brain binding currently configured for a local Connection (grok, a
    /// catalog brain, or dynamic). Defaults to `.grok` for anything we can't resolve
    /// (e.g. a remote item). Read by `EditBrainView`.
    func binding(for item: InstanceItem) -> BrainBinding {
        connections.first(where: { $0.id == item.id })?.brain ?? .grok
    }

    /// Human label for the ACP agent a command-based (`.grok`) Node runs, inferred
    /// from its launch command — grok, Claude Code, or a custom ACP agent — so the
    /// UI can name it honestly instead of always saying "grok".
    func acpAgentLabel(for item: InstanceItem) -> String {
        Self.acpAgentLabel(forCommand: connections.first { $0.id == item.id }?.command ?? "")
    }
    static func acpAgentLabel(forCommand command: String) -> String {
        let c = command.lowercased()
        if c.contains("claude-code-acp") || c.contains("claude-agent-acp") { return "Claude Code" }
        if c.hasSuffix("/grok") || c == "grok" || c.contains("/.grok/") { return "grok" }
        return c.isEmpty ? "ACP agent" : "Custom ACP agent"
    }

    /// Swap a local Connection's brain (the LLM that backs it). Persists the new
    /// binding, then restarts the Node so the next turn runs on the new backend —
    /// `restartInstance` drops the cached session and rebinds; the transcript
    /// reloads from history (see `design/12-model-agnostic-runtime.md`, Phase F).
    /// No-op for remote items or a no-change swap.
    func setBrain(_ brain: BrainBinding, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }),
              connections[idx].brain != brain else { return }
        connections[idx].brain = brain
        persistAndRestartIfLive(idx: idx, item: item)
    }

    // MARK: - Brain catalog (named brains the user curates)

    /// Add a profile to the catalog and persist. Returns its id.
    @discardableResult
    func addBrainProfile(name: String, backend: AgentBackend) -> UUID {
        let profile = BrainProfile(name: name, backend: backend)
        brainCatalog.profiles.append(profile)
        ConnectionStore.saveBrainCatalog(brainCatalog)
        return profile.id
    }

    /// Update a catalog profile in place, persist, and restart any **running** Node
    /// whose resolved brain references it so the change takes effect now.
    func updateBrainProfile(_ profile: BrainProfile) {
        guard let idx = brainCatalog.profiles.firstIndex(where: { $0.id == profile.id }),
              brainCatalog.profiles[idx] != profile else { return }
        brainCatalog.profiles[idx] = profile
        ConnectionStore.saveBrainCatalog(brainCatalog)
        restartNodesReferencing(profileID: profile.id)
    }

    /// Remove a catalog profile. Nodes/tiers referencing it become dangling and
    /// resolve to grok until repointed; running referencing Nodes are restarted.
    func removeBrainProfile(_ id: UUID) {
        guard brainCatalog.profiles.contains(where: { $0.id == id }) else { return }
        brainCatalog.profiles.removeAll { $0.id == id }
        ConnectionStore.saveBrainCatalog(brainCatalog)
        restartNodesReferencing(profileID: id)
    }

    /// Restart every running local Node whose binding resolves through `profileID`
    /// (a direct `.profile` pin, or a `.dynamic` Node whose default tier maps to it).
    private func restartNodesReferencing(profileID: UUID) {
        for item in instances where item.serverID == nil {
            guard let conn = connections.first(where: { $0.id == item.id }),
                  item.status == .running || item.status == .starting,
                  bindingReferences(conn.brain, profileID: profileID) else { continue }
            restartLive(config: conn, item: item)
        }
    }

    private func bindingReferences(_ binding: BrainBinding, profileID: UUID) -> Bool {
        switch binding {
        case .profile(let id):
            return id == profileID
        case .dynamic(let defaultTier, _):
            if case .profile(let id) = hostTierMap.ref(for: defaultTier) { return id == profileID }
            return false
        case .grok, .inlineLegacy:
            return false
        }
    }

    /// A readable default name for a backend, e.g. "Cerebras · gpt-oss-120b".
    /// Used by the catalog UI and by migration of legacy inline brains.
    static func defaultName(for backend: AgentBackend) -> String {
        switch backend {
        case .grokACP: return "grok"
        case .onboard(let path): return "Onboard · \((path as NSString).lastPathComponent)"
        case .gemini(let model, _): return "Gemini · \(model)"
        case .acpStdio(let command, _, let label): return label ?? acpAgentLabel(forCommand: command)
        case .openAICompatible(let baseURL, let model, _):
            let provider = providerName(forBaseURL: baseURL)
            return model.isEmpty ? provider : "\(provider) · \(model)"
        }
    }

    /// Best-effort provider label from a base URL host (Groq / Cerebras / xAI / …).
    private static func providerName(forBaseURL baseURL: String) -> String {
        let host = URL(string: baseURL)?.host?.lowercased() ?? baseURL.lowercased()
        if host.contains("groq") { return "Groq" }
        if host.contains("cerebras") { return "Cerebras" }
        if host.contains("x.ai") { return "xAI" }
        if host.contains("generativelanguage") || host.contains("googleapis") { return "Gemini" }
        if host.contains("openai.com") { return "OpenAI" }
        if host.contains("localhost") || host.contains("127.0.0.1") { return "Local" }
        return host.isEmpty ? "API" : host
    }

    /// One-time migration: rewrite any `.inlineLegacy(backend)` brain (from a
    /// pre-catalog config) into a find-or-created catalog profile, so every binding
    /// references the catalog. Persists catalog + connections only if something
    /// changed. Safe to call on every launch.
    private func migrateBrainsIfNeeded() {
        var connectionsChanged = false
        for i in connections.indices {
            guard case .inlineLegacy(let backend) = connections[i].brain else { continue }
            let id = brainCatalog.findOrCreate(backend: backend, name: Self.defaultName(for: backend))
            connections[i].brain = .profile(id)
            connectionsChanged = true
        }
        if connectionsChanged {
            ConnectionStore.saveBrainCatalog(brainCatalog)
            ConnectionStore.save(connections)
        }
    }

    // MARK: - MCP server registry + per-Node grants

    /// Add an MCP server to the registry and persist. Returns its id.
    @discardableResult
    func addMCPServer(name: String, transport: MCPTransport) -> UUID {
        let server = MCPServerConfig(name: name, transport: transport)
        mcpRegistry.servers.append(server)
        ConnectionStore.saveMCPRegistry(mcpRegistry)
        return server.id
    }

    /// Update an MCP server in place, persist, and restart any **running** Node that
    /// grants it (the new transport/args take effect on the next session).
    func updateMCPServer(_ server: MCPServerConfig) {
        guard let idx = mcpRegistry.servers.firstIndex(where: { $0.id == server.id }),
              mcpRegistry.servers[idx] != server else { return }
        mcpRegistry.servers[idx] = server
        ConnectionStore.saveMCPRegistry(mcpRegistry)
        restartNodesGranting(serverID: server.id)
    }

    /// Remove an MCP server from the registry. Per-Node grants that named it become
    /// no-ops (the id is filtered out at use); running Nodes that granted it restart.
    func removeMCPServer(_ id: UUID) {
        guard mcpRegistry.servers.contains(where: { $0.id == id }) else { return }
        mcpRegistry.servers.removeAll { $0.id == id }
        ConnectionStore.saveMCPRegistry(mcpRegistry)
        restartNodesGranting(serverID: id)
    }

    /// The MCP servers a local Connection currently grants (`nil` ⇒ all). Read by the
    /// per-Node MCP access sheet.
    func mcpGrant(for item: InstanceItem) -> [UUID]? {
        connections.first(where: { $0.id == item.id })?.grantedMCPServerIDs
    }

    /// Set a local Connection's MCP access grant (`nil` = all, `[]` = none, `[ids]` =
    /// subset). Persists and restarts a running Node so the new set is injected into
    /// its next session. No-op for remote items or a no-change update.
    func setMCPGrant(_ ids: [UUID]?, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }),
              connections[idx].grantedMCPServerIDs != ids else { return }
        connections[idx].grantedMCPServerIDs = ids
        persistAndRestartIfLive(idx: idx, item: item)
    }

    /// Restart every running local Node whose grant includes `serverID` (or grants
    /// all, `nil`) so a registry change to that server takes effect now.
    private func restartNodesGranting(serverID: UUID) {
        for item in instances where item.serverID == nil {
            guard let conn = connections.first(where: { $0.id == item.id }),
                  item.status == .running || item.status == .starting else { continue }
            let grantsIt = conn.grantedMCPServerIDs == nil || conn.grantedMCPServerIDs!.contains(serverID)
            if grantsIt { restartLive(config: conn, item: item) }
        }
    }

    /// The ACP auto-approval policy currently configured for a local Connection (how
    /// much of its tool prompts the app answers without a human). Defaults `.manual`.
    func autoApproval(for item: InstanceItem) -> AutoApproval {
        connections.first(where: { $0.id == item.id })?.autoApproval ?? .manual
    }

    /// Set a local Connection's ACP auto-approval policy. Persists and restarts a
    /// running Node so the new policy takes effect (it's captured at session start).
    func setAutoApproval(_ policy: AutoApproval, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }),
              connections[idx].autoApproval != policy else { return }
        connections[idx].autoApproval = policy
        persistAndRestartIfLive(idx: idx, item: item)
    }

    /// The design-oracle enforcement mode for a local Connection. Defaults to
    /// `.shadow` (observe only). Read by `EditToolPolicyView` and the inspector.
    func oracleEnforcement(for item: InstanceItem) -> OracleEnforcement {
        connections.first(where: { $0.id == item.id })?.oracleEnforcement ?? .shadow
    }

    /// Set a local Connection's oracle enforcement mode. Persists and restarts a
    /// running Node so the new mode takes effect (it's captured at session start).
    func setOracleEnforcement(_ mode: OracleEnforcement, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }),
              connections[idx].oracleEnforcement != mode else { return }
        connections[idx].oracleEnforcement = mode
        persistAndRestartIfLive(idx: idx, item: item)
    }

    /// The tool/capability policy currently configured for a local Connection — what
    /// its brain is allowed to *do* (read / write / execute, and any allowlist).
    /// Defaults to `.unrestricted`. Read by `EditToolPolicyView`.
    func toolPolicy(for item: InstanceItem) -> ToolPolicy {
        connections.first(where: { $0.id == item.id })?.toolPolicy ?? .unrestricted
    }

    /// Set a local Connection's tool/capability policy (the app-owned guardrail
    /// layer — design/11, design/12 Phase C). Persists it and restarts a running
    /// Node so the new policy takes effect: the API tool loop captures the policy at
    /// session creation, so a live swap needs a fresh session. No-op for remote
    /// items or a no-change update.
    func setToolPolicy(_ policy: ToolPolicy, for item: InstanceItem) {
        guard item.serverID == nil,
              let idx = connections.firstIndex(where: { $0.id == item.id }),
              connections[idx].toolPolicy != policy else { return }
        connections[idx].toolPolicy = policy
        persistAndRestartIfLive(idx: idx, item: item)
    }

    /// Save the connection list and, if the Node is currently live, restart it so a
    /// config change (brain / tool policy) takes effect immediately — the transcript
    /// reloads from history. A stopped Node picks the change up on its next launch.
    /// Shared tail of `setBrain` / `setToolPolicy`.
    private func persistAndRestartIfLive(idx: Int, item: InstanceItem) {
        ConnectionStore.save(connections)
        if item.status == .running || item.status == .starting {
            restartLive(config: connections[idx], item: item)
        }
    }

    /// Restart a currently-live Node against `config` and reflect status on its item.
    /// The transcript reloads from history; the live UI re-binds (see
    /// `GrokBuildManager.restartInstance`). Caller has already persisted `config`.
    private func restartLive(config: ManagedConnection, item: InstanceItem) {
        let manager = self.manager
        let server = self.server
        item.status = .starting
        Task {
            do {
                let updated = try await manager.restartInstance(config)
                item.status = updated.status
            } catch {
                item.status = .errored
            }
            await server.broadcastInstancesIfChanged()
        }
    }

    /// Replace the host tier map (machine config). Persists it, then restarts any
    /// **running dynamic** Node so its newly-resolved backend takes effect now —
    /// pinned Nodes are unaffected, and stopped Nodes pick it up on next launch.
    /// Edited in Settings ▸ Brains (see `design/12-model-agnostic-runtime.md`).
    func setHostTierMap(_ map: HostTierMap) {
        guard map != hostTierMap else { return }
        hostTierMap = map
        ConnectionStore.saveTierMap(map)
        for item in instances where item.serverID == nil {
            guard let conn = connections.first(where: { $0.id == item.id }),
                  case .dynamic = conn.brain,
                  item.status == .running || item.status == .starting else { continue }
            restartLive(config: conn, item: item)
        }
    }

    // MARK: - Team template registry

    func saveCustomTeamTemplate(_ template: TeamTemplate) {
        guard !template.isBuiltin else { return }
        var list = customTeamTemplates
        if let idx = list.firstIndex(where: { $0.id == template.id }) {
            list[idx] = template
        } else {
            list.append(template)
        }
        customTeamTemplates = list
        ConnectionStore.saveTeamTemplates(TeamTemplateRegistry(custom: list))
    }

    func deleteCustomTeamTemplate(id: String) {
        guard !TeamTemplate.builtinIDs.contains(id) else { return }
        customTeamTemplates.removeAll { $0.id == id }
        ConnectionStore.saveTeamTemplates(TeamTemplateRegistry(custom: customTeamTemplates))
    }

    /// Copy a built-in (or custom) template into an editable custom draft.
    func duplicateTeamTemplate(_ source: TeamTemplate) -> TeamTemplate {
        var copy = source
        let base = source.isBuiltin ? source.id : "\(source.id)-copy"
        var candidate = TeamTemplate.slug(from: base)
        var n = 2
        while fleetTeamTemplates.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        copy = TeamTemplate(
            id: candidate,
            title: source.isBuiltin ? "\(source.title) (copy)" : "\(source.title) copy",
            summary: source.summary,
            members: source.members,
            requiresOrchestratedFleet: source.requiresOrchestratedFleet
        )
        return copy
    }

    /// Ask grok to draft a role prompt for a template member from its plain
    /// name/description and the rest of the team shape.
    func draftTemplateMemberPrompt(template: TeamTemplate, memberIndex: Int) async -> String {
        guard memberIndex >= 0, memberIndex < template.members.count else { return "" }
        let member = template.members[memberIndex]
        let roleWord = member.isOrchestrator
            ? "the orchestrator that coordinates the team and delegates via `delegate`"
            : "a specialist worker that performs one focused part of the job"
        let teammates = template.members.enumerated()
            .filter { $0.offset != memberIndex }
            .map { "\($0.element.displayName) — \($0.element.memberDescription)" }
        let teamLine = teammates.isEmpty
            ? ""
            : "Other team members: \(teammates.joined(separator: "; "))."
        let meta = """
        You are authoring a fleet team template called "\(template.title)" (\(template.summary)).
        Write a concise role/system prompt (second person, imperative) for "\(member.displayName)": \
        \(member.memberDescription). This agent is \(roleWord). \(teamLine)
        Orchestrator never executes work itself; workers return structured findings for synthesis.
        Keep under ~200 words. Output ONLY the role prompt text — no preamble, headings, or quotes.
        """
        let command = Self.defaultGrokCommand
        let out = await Self.runGrokHeadless(command: command, prompt: meta, cwd: nil)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var defaultGrokCommand: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok")
            .path
    }

    /// Ask grok (headless, one-shot) to draft a role prompt for `item` from its name
    /// and its team (parent + siblings, or its children). Returns "" on failure; the
    /// caller shows it in an editable field. See `grok-stdio-system-prompt`.
    func draftRolePrompt(for item: InstanceItem) async -> String {
        guard let conn = connections.first(where: { $0.id == item.id }) else { return "" }
        let active = connections.filter { !$0.archived }
        let team: [String]
        if item.role == .orchestrator {
            team = active.filter { $0.parentID == item.id }.map(\.name)
        } else if let pid = item.parentID, let parent = active.first(where: { $0.id == pid }) {
            team = [parent.name] + active.filter { $0.parentID == pid && $0.id != item.id }.map(\.name)
        } else {
            team = []
        }
        let roleWord = item.role == .orchestrator
            ? "an orchestrator that coordinates its child agents and decides what to do next"
            : "a worker agent that performs one part of the team's job"
        let teamLine = team.isEmpty ? "It has no named teammates yet."
            : "Its teammates are: \(team.joined(separator: ", "))."
        let meta = """
        You are configuring a multi-agent team. Write a concise, direct role/system prompt \
        (second person, imperative) for an agent named "\(item.name)", which is \(roleWord). \
        \(teamLine) Infer its specific responsibility from its name and the team's shape. \
        Keep it under ~150 words. Output ONLY the role prompt text — no preamble, no headings, no quotes.
        """
        let out = await Self.runGrokHeadless(command: conn.command, prompt: meta, cwd: conn.workingDirectory)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Run `grok -p <prompt>` headless with the user's login-shell environment and
    /// return stdout. Off the main actor; a watchdog terminates a hung run.
    nonisolated static func runGrokHeadless(command: String, prompt: String, cwd: String?,
                                            timeout: TimeInterval = 120) async -> String? {
        final class Box: @unchecked Sendable { let p = Process() }
        let box = Box()
        return await Task.detached(priority: .userInitiated) { [box] () -> String? in
            let p = box.p
            p.executableURL = URL(fileURLWithPath: command)
            p.arguments = ["-p", prompt]
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.environment = LoginShellEnvironment.shared
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let watchdog = Task { [box] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if box.p.isRunning { box.p.terminate() }
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Launches a Connection's grok process and reflects status on its UI item.
    /// Shared launch path used both by `addRealConnection` and the boot-time
    /// auto-restart pass.
    private func launchConnection(_ config: ManagedConnection, startingItem: InstanceItem? = nil) async {
        let item = startingItem ?? instances.first(where: { $0.id == config.id })
        item?.status = .starting
        do {
            let updated = try await manager.startInstance(config)
            item?.status = updated.status
            await server.broadcastInstancesIfChanged()
        } catch {
            item?.status = .errored
            item?.conversation.appendSystem("Failed to launch: \(error.localizedDescription)", isError: true)
        }
    }

    /// Stops a real local instance, or disconnects/removes a remote link's
    /// session for a remote-tagged item (the underlying remote process is
    /// the remote Mac's concern).
    func stop(_ item: InstanceItem) {
        item.status = .stopping
        let server = self.server
        Task {
            if item.serverID == nil {
                await manager.stopInstance(id: item.id)
                await server.broadcastInstancesIfChanged()
            }
            item.status = .stopped
        }
    }

    // MARK: - Name lookup (collision detection for the Add form)

    /// First active (non-archived) Connection with this name, case-insensitively.
    /// `nil` ⇒ name is free among active Connections. Used by the Add form to
    /// reject duplicates outright.
    func activeConnection(named name: String) -> ManagedConnection? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.first { !$0.archived && $0.name.lowercased() == key }
    }

    /// First archived Connection with this name, case-insensitively. Used by
    /// the Add form to offer Restore (the user is probably looking for their
    /// previous config + history) vs Create-new (explicit fresh start).
    func archivedConnection(named name: String) -> ManagedConnection? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return connections.first { $0.archived && $0.name.lowercased() == key }
    }

    /// Renames a Connection in the registry (and on disk). Used by the
    /// Create-new path to disambiguate an archived "X" from a freshly-added
    /// active "X" by suffixing the archived entry with an ISO-date marker.
    func renameConnection(_ connection: ManagedConnection, to newName: String) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx].name = newName
        ConnectionStore.save(connections)
        if let item = instances.first(where: { $0.id == connection.id }) {
            item.name = newName
        }
    }

    // MARK: - Archive / Restore / Delete Permanently

    /// Connections currently in the archived state (hidden from sidebar + remote).
    var archivedConnections: [ManagedConnection] {
        connections.filter { $0.archived }
    }

    /// Archive a local Connection: stop its process if running, hide it from the
    /// main sidebar and from every remote GKSC. Reversible via `restore`.
    func archive(_ item: InstanceItem) {
        guard let idx = connections.firstIndex(where: { $0.id == item.id }) else { return }
        let server = self.server
        Task {
            await manager.stopInstance(id: item.id)
            await server.broadcastInstancesIfChanged()
        }
        connections[idx].archived = true
        ConnectionStore.save(connections)
        instances.removeAll { $0.id == item.id }
        if selectedInstanceID == item.id { selectedInstanceID = instances.first?.id }
    }

    /// Restore an archived Connection — bring it back into the main sidebar in a
    /// stopped state. We do NOT auto-launch even if `autoRestart` is true;
    /// the user launches manually, or the next GKSS boot honors the flag.
    func restore(_ connection: ManagedConnection) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx].archived = false
        ConnectionStore.save(connections)
        let item = InstanceItem(
            id: connection.id, name: connection.name, status: .stopped,
            driver: LiveConversationDriver(manager: manager, instanceID: connection.id),
            role: connection.role, parentID: connection.parentID, rolePrompt: connection.rolePrompt
        )
        instances.append(item)
        item.conversation.startSubscription()
    }

    /// Permanently delete an archived Connection — drops config and history dir.
    /// Caller (the UI) is responsible for the destructive confirmation.
    func deletePermanently(_ connection: ManagedConnection) {
        connections.removeAll { $0.id == connection.id }
        ConnectionStore.save(connections)
        ConnectionStore.deleteHistoryDirectory(for: connection.id)
    }

    /// One-step permanent delete of a *live* (non-archived) local Connection —
    /// the destructive alternative to `archive`. Stops its process, removes it
    /// from the sidebar, fixes selection, and drops its config + history dir.
    /// Caller (the UI) owns the destructive confirmation. (Archived entries use
    /// `deletePermanently` directly from the Archived sheet.)
    func delete(_ item: InstanceItem) {
        guard let connection = connections.first(where: { $0.id == item.id }) else { return }
        let server = self.server
        Task {
            await manager.stopInstance(id: item.id)
            await server.broadcastInstancesIfChanged()
        }
        instances.removeAll { $0.id == item.id }
        if selectedInstanceID == item.id { selectedInstanceID = instances.first?.id }
        deletePermanently(connection)
    }

    // MARK: - Remote servers

    /// Saves a new remote server, connects to it, and adds any returned
    /// instances to the sidebar.
    func addRemoteServer(name: String, host: String, localHost: String? = nil, port: UInt16) {
        let config = RemoteServerConfig(name: name, host: host, localHost: localHost, port: port)
        var saved = RemoteServerStore.load()
        saved.append(config)
        RemoteServerStore.save(saved)

        let link = RemoteServerLink(config: config)
        remoteLinks.append(link)
        Task { await connectAndAttach(link) }
    }

    /// Updates a remote server's connection details and reconnects with the new
    /// config (the link's config is immutable, so the link is recreated).
    func updateRemoteServer(_ updated: RemoteServerConfig) {
        var saved = RemoteServerStore.load()
        if let i = saved.firstIndex(where: { $0.id == updated.id }) { saved[i] = updated } else { saved.append(updated) }
        RemoteServerStore.save(saved)

        if let old = remoteLinks.first(where: { $0.id == updated.id }) {
            Task { await old.disconnect() }
        }
        instances.removeAll { $0.serverID == updated.id }

        let link = RemoteServerLink(config: updated)
        if let i = remoteLinks.firstIndex(where: { $0.id == updated.id }) { remoteLinks[i] = link }
        else { remoteLinks.append(link) }
        Task { await connectAndAttach(link) }
    }

    /// Manually reconnect a remote server after it dropped/failed. Re-runs the
    /// connect + instance-sync flow; on success `link.generation` bumps and the
    /// reconcile loop rebuilds this server's Connections against the fresh
    /// session (see `reconcileInstanceItems`).
    func reconnectRemoteServer(_ link: RemoteServerLink) {
        Task { await connectAndAttach(link) }
    }

    /// Removes a remote server: disconnects, drops its instances, persists.
    func removeRemoteServer(_ link: RemoteServerLink) {
        Task { await link.disconnect() }
        instances.removeAll { $0.serverID == link.id }
        remoteLinks.removeAll { $0.id == link.id }
        let saved = RemoteServerStore.load().filter { $0.id != link.id }
        RemoteServerStore.save(saved)
    }

    /// Connect to a link and mirror its instances into the sidebar's mixed list.
    private func connectAndAttach(_ link: RemoteServerLink) async {
        await link.connect()
        // Observe its `instances` array on the MainActor by polling once after
        // connect (the link mutates it via @Observable; here we eagerly create
        // matching InstanceItems for what came back so the UI populates fast).
        // The link continues to update `instances` as events arrive; we'll
        // refresh by re-syncing on a small repeat for v1.
        await syncRemoteInstances(for: link)
    }

    /// One-shot sync — for v1. Future: an AsyncStream from the link.
    private func syncRemoteInstances(for link: RemoteServerLink) async {
        // Re-run the sync periodically until disconnected.
        while !Task.isCancelled, link.state == .connected || link.state == .connecting {
            await reconcileInstanceItems(link: link)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Tracks the connection generation last reconciled per server, so a
    /// reconnect (which bumps `link.generation`) triggers a rebuild of that
    /// server's Connection items against the fresh session.
    private var reconciledGenerations: [UUID: Int] = [:]

    /// Bring the sidebar's `instances` in sync with `link.instances`: add new,
    /// remove gone; each remote item gets its own `RemoteConversationDriver`.
    private func reconcileInstanceItems(link: RemoteServerLink) async {
        let serverID = link.id
        // On a fresh connection generation (first connect OR a reconnect), drop
        // the server's existing items so they rebuild against the new session —
        // the old drivers point at a now-invalidated session and would never
        // recover. New items re-use the same instance IDs, so the current
        // selection is preserved and each fresh subscription reloads the server's
        // authoritative snapshot.
        if reconciledGenerations[serverID] != link.generation {
            reconciledGenerations[serverID] = link.generation
            instances.removeAll { $0.serverID == serverID }
        }
        let remote = link.instances
        // Remove items for this server that no longer exist remotely.
        instances.removeAll { item in
            item.serverID == serverID && !remote.contains(where: { $0.id == item.id })
        }
        // Reflect host-side changes (tree role/parent + rename) onto existing items.
        for inst in remote {
            guard let item = instances.first(where: { $0.id == inst.id && $0.serverID == serverID }) else { continue }
            if item.role != inst.role { item.role = inst.role }
            if item.parentID != inst.parentID { item.parentID = inst.parentID }
            if item.rolePrompt != inst.rolePrompt { item.rolePrompt = inst.rolePrompt }
            if item.name != inst.name { item.name = inst.name }
        }
        // Add items for new remote instances.
        for inst in remote where !instances.contains(where: { $0.id == inst.id }) {
            guard let driver = await link.driver(for: inst.id) else { continue }
            let item = InstanceItem(id: inst.id, name: inst.name, status: inst.status,
                                    driver: driver, serverID: serverID,
                                    role: inst.role, parentID: inst.parentID, rolePrompt: inst.rolePrompt)
            instances.append(item)
            // Subscribe immediately so this remote Connection's live transcript
            // accumulates in the background — switching away and back (or to
            // another Connection mid-turn) no longer blanks it.
            item.conversation.startSubscription()
        }
    }

    // MARK: - Local listener

    private func applyServerToggle() {
        let server = self.server
        let port = self.serverPort
        let enabled = self.serverEnabled
        Task {
            if enabled {
                try? await server.start(port: port)
            } else {
                await server.stop()
            }
        }
    }

    // MARK: - Orchestration DB inspector (#133)

    func orchestrationTables() async -> [String] {
        (try? await orchestrationDB.listTables()) ?? []
    }

    func orchestrationDBSummary() async -> String {
        await orchestrationDB.debugDump()
    }

    func orchestrationTablePreview(_ name: String, limit: Int = 5) async -> String {
        guard let rows = try? await orchestrationDB.query(table: name, predicate: nil, limit: limit) else {
            return "(unable to query \(name))"
        }
        if rows.isEmpty { return "(no rows)" }
        return rows.map { row in
            row.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        }.joined(separator: "\n")
    }

    // MARK: - App-quit cleanup

    /// Single entry point for clean shutdown. Stops the local listener (releases
    /// the port), disconnects every remote link, and terminates every running
    /// grok child process this Mac launched (SIGTERM → wait → SIGKILL survivors).
    /// Called from `AppDelegate.applicationWillTerminate` under a bounded
    /// semaphore so the OS doesn't yank us before we finish.
    func shutdownAll(timeout: TimeInterval = 1.0) async {
        await server.stop()
        await orchestrationMCP.stop()
        OrchestrationMCPServer.isActive = false
        for link in remoteLinks { await link.disconnect() }
        await manager.terminateAll(timeout: timeout)
    }
}
