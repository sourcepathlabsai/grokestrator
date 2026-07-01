import Foundation
import GrokestratorCore

/// The primary integration surface for Grok Build functionality inside the Mac app.
///
/// `GrokBuildManager` owns the lifecycle of Grok Build instances and provides
/// a clean, high-level API that the rest of the application (UI, ServerState, etc.)
/// can use without needing to know about processes or the raw ACP protocol.
///
/// This is the recommended entry point from `GrokestratorMacApp` or a central
/// `ServerController`.
public actor GrokBuildManager {
    private let server = GrokBuildServer()
    private var instanceStates: [UUID: ManagedInstance] = [:]
    /// Optional hook for the Run view sidebar — records delegation lifecycle events.
    private var delegationRunCallback: (@Sendable (DelegationRunUpdate) -> Void)?

    public init() {
        // We will register death handlers when conversations are created
    }

    /// Starts a new Grok Build instance from its configuration.
    /// Returns an updated `ManagedInstance` reflecting the running state.
    public func startInstance(_ config: ManagedInstance) async throws -> ManagedInstance {
        let (_, updated) = try await server.startInstance(config)
        instanceStates[config.id] = updated
        return updated
    }

    public func stopInstance(id: UUID) async {
        await server.stopInstance(id: id)
        if var inst = instanceStates[id] {
            inst.status = .stopped
            instanceStates[id] = inst
        }
    }

    /// Restart a Node against a (possibly changed) config — e.g. after switching its
    /// brain. Drops the cached conversation so the next `conversation(for:)` rebinds
    /// to the **new** backend session; the transcript reloads from persisted history.
    public func restartInstance(_ config: ManagedInstance, trackTransition: Bool = true) async throws -> ManagedInstance {
        if trackTransition { beginTransition(config.id) }
        defer { if trackTransition { endTransition(config.id) } }

        // End the old conversation's broadcast streams first: resilient subscribers
        // (LiveConversationDriver) re-subscribe and re-bind to the rebuilt
        // conversation, so the live UI follows the brain swap without a reopen.
        await activeConversations[config.id]?.finishSubscribers()
        await server.stopInstance(id: config.id)
        activeConversations.removeValue(forKey: config.id)
        let updated = try await startInstance(config)
        // Rebuild the conversation and finish ACP `initialize` + `session/new` (and MCP
        // startup) before callers can prompt — absorbs init latency here instead of on
        // the user's first message after a role restart (#185).
        let convo = try await conversation(for: config.id)
        _ = try await convo.capabilities()
        return updated
    }

    /// Terminates every running grok process this Mac is hosting. Drains the
    /// active-conversation table so callers don't hand back dead handles after
    /// a shutdown. Used by app-quit cleanup.
    public func terminateAll(timeout: TimeInterval = 1.0) async {
        await server.stopAll(timeout: timeout)
        for (id, var inst) in instanceStates {
            inst.status = .stopped
            instanceStates[id] = inst
        }
        activeConversations.removeAll()
    }

    /// Returns the current view of all managed instances (suitable for updating ServerState).
    public func currentInstances() -> [ManagedInstance] {
        Array(instanceStates.values)
    }

    /// Update a running instance's orchestration-tree metadata (`role`/`parentID`)
    /// so the next `broadcastInstancesIfChanged` carries the new tree to remote
    /// clients. No-op if the instance isn't currently tracked (it'll pick the
    /// values up from its config on next launch).
    public func updateTreeMetadata(id: UUID, role: NodeRole, parentID: UUID?) {
        guard var state = instanceStates[id] else { return }
        state.role = role
        state.parentID = parentID
        instanceStates[id] = state
    }

    /// Update a Node's role/system prompt. Updates the tracked state (so a future
    /// session primes with it) and the live conversation (which resets `primed`, so
    /// the next turn re-injects the new role without restarting the process).
    public func setRolePrompt(for id: UUID, _ prompt: String?) async {
        if var state = instanceStates[id] {
            state.rolePrompt = prompt
            instanceStates[id] = state
        }
        if let convo = activeConversations[id] {
            await convo.setRolePrompt(prompt)
        }
    }

    /// Apply a role-prompt change with an explicit transition mode (issue #177).
    /// Returns an updated `ManagedInstance` when a restart ran; `nil` for re-prime only.
    public func applyRoleTransition(
        for id: UUID,
        prompt: String?,
        config: ManagedInstance,
        mode: RoleTransitionMode
    ) async throws -> ManagedInstance? {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed

        switch mode {
        case .reprimeOnly:
            await setRolePrompt(for: id, value)
            return nil
        case .restartWithGist, .restartFresh:
            // Hold prompts and clear-history until gist compaction + restart + handshake
            // finish — prevents racing the old client or a half-ready new one (#185).
            beginTransition(id)
            defer { endTransition(id) }

            var gistWire: String?
            if mode == .restartWithGist {
                gistWire = await sessionGistWire(for: id)
            } else {
                pendingSessionGists.removeValue(forKey: id)
                ConnectionStore.clearPendingSessionGist(for: id)
            }

            if let gistWire {
                pendingSessionGists[id] = gistWire
                ConnectionStore.savePendingSessionGist(gistWire, for: id)
                if let convo = activeConversations[id] {
                    await convo.appendMarkerTurn(
                        "── Role updated; agent restarted with compact prior context ──"
                    )
                } else {
                    ConnectionStore.appendMarkerToHistory(
                        for: id,
                        prompt: "── Role updated; agent restarted with compact prior context ──"
                    )
                }
            } else if mode == .restartFresh {
                let marker = "── Role updated; agent restarted (fresh context) ──"
                if let convo = activeConversations[id] {
                    await convo.appendMarkerTurn(marker)
                } else {
                    ConnectionStore.appendMarkerToHistory(for: id, prompt: marker)
                }
            }

            var updated = config
            updated.rolePrompt = value
            if var state = instanceStates[id] {
                state.rolePrompt = value
                instanceStates[id] = state
            }

            let isLive = await server.getClient(for: id) != nil
            if isLive {
                return try await restartInstance(updated, trackTransition: false)
            }
            await setRolePrompt(for: id, value)
            return updated
        }
    }

    private func sessionGistWire(for id: UUID) async -> String? {
        let turns: [AgentTurn]
        if let convo = activeConversations[id] {
            turns = await convo.getHistory()
        } else {
            turns = ConnectionStore.loadHistoryTurns(for: id)
        }
        let services = ContextCompactionServices(
            summarizer: FastTierSummarizer(),
            retriever: EmbeddingRetriever()
        )
        return await ContextManager.wirePreambleForTransition(from: turns, services: services)
    }

    private func consumePendingSessionGist(for id: UUID) -> String? {
        if let inMemory = pendingSessionGists.removeValue(forKey: id) { return inMemory }
        return ConnectionStore.consumePendingSessionGist(for: id)
    }

    /// Advanced escape hatch. Most Mac app code should never call this.
    internal func _client(for id: UUID) async -> (any AgentSession)? {
        await server.getClient(for: id)
    }

    /// Lower-level escape hatch that still leaks ACP details.
    /// Most Mac app code should use `conversation(for:)` + the high-level sendPrompt on the conversation instead.
    /// Only for advanced debugging or when you genuinely need the raw ACP stream.
    public func runPrompt(on instanceID: UUID, prompt: String) async throws -> (sessionId: String, events: AsyncStream<ACPEvent>) {
        guard let client = await server.getClient(for: instanceID) else {
            throw GrokBuildError.instanceManagementError("No active client for instance \(instanceID)")
        }
        let sessionId = try await client.createSession(metadata: nil)
        let events = try await client.sendPrompt(sessionId: sessionId, prompt: prompt)
        return (sessionId, events)
    }

    /// Restores conversations for all currently running instances (called on app launch / server restart).
    public func restoreActiveConversations() async throws {
        let running = await server.listRunningInstances()
        for inst in running {
            _ = try? await conversation(for: inst.id)
        }
    }

    // MARK: - Orchestration (Phase 1c: delegate routing)

    /// Wire delegation lifecycle events into `DelegationRunStore` (Run view sidebar).
    public func setDelegationRunCallback(_ callback: (@Sendable (DelegationRunUpdate) -> Void)?) {
        delegationRunCallback = callback
    }

    /// The router behind the Orchestration MCP `delegate` tool: resolve a child
    /// Connection by name, send it `task` as a prompt (so the child's transcript
    /// shows the delegated turn live — watchable on every device), await the
    /// turn's final answer, and return it to the calling orchestrator. Name
    /// resolution is global across local Connections for now (one level; scoping
    /// to the *caller's* children waits for per-orchestrator MCP identity).
    /// See `design/11-orchestration-platform.md`.
    public func delegate(callerID: UUID?, toChildNamed name: String, task: String, timeout: TimeInterval = 120) async -> String {
        let live = instanceStates.values.filter { !$0.archived }
        let target: ManagedInstance?
        if let callerID {
            target = OrchestrationTree.resolveDescendant(named: name, under: callerID, in: live)
        } else {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            target = live.first(where: { $0.name.lowercased() == key })
        }
        let candidates: [ManagedInstance] = if let callerID {
            OrchestrationTree.descendants(of: callerID, in: live)
        } else {
            Array(live)
        }
        guard let target else {
            let names = candidates.map(\.name).sorted().joined(separator: ", ")
            let scope = callerID == nil ? "Available" : "Your descendants"
            return "No descendant named \"\(name)\". \(scope): \(names.isEmpty ? "(none — add child agents under this orchestrator)" : names)."
        }

        let runID = UUID()
        if let callerID {
            delegationRunCallback?(.started(DelegationRun(
                id: runID, parentID: callerID, childID: target.id,
                childName: target.name, task: task
            )))
        }

        let result: String
        do {
            // Subscribe before prompting so we don't miss the turn's events.
            let stream = try await subscribe(to: target.id)
            _ = try await sendPrompt(to: target.id, prompt: task)
            let raw = await Self.awaitFinalAnswer(stream, timeout: timeout, child: target.name)
            result = ChildFindingEnvelope.formatDelegateResult(raw, childName: target.name)
        } catch {
            result = "Delegation to \"\(target.name)\" failed: \(error.localizedDescription)"
        }

        if callerID != nil {
            delegationRunCallback?(.finished(
                id: runID,
                status: Self.inferDelegationStatus(result: result),
                resultPreview: String(result.prefix(200))
            ))
        }
        return result
    }

    private static func inferDelegationStatus(result: String) -> DelegationRunStatus {
        if result.contains("delegation timed out") || result.contains("timed out") { return .timedOut }
        if result.hasPrefix("Delegation to") && result.contains("failed") { return .failed }
        if result.hasPrefix("Child \"") && result.contains("error:") { return .failed }
        if result.hasPrefix("No child agent") { return .failed }
        return .completed
    }

    /// Consume a child's broadcast stream until its turn completes (or times out),
    /// returning the final answer text. Runs the consume and a timeout concurrently.
    private static func awaitFinalAnswer(_ stream: AsyncStream<ConnectionStreamEvent>,
                                         timeout: TimeInterval, child: String) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await event in stream {
                    guard case .update(let update) = event else { continue }
                    switch update {
                    case .turnComplete(let final): return final ?? ""
                    case .error(let msg): return "Child \"\(child)\" error: \(msg)"
                    default: continue
                    }
                }
                return nil   // stream ended without completing
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return "\u{0}TIMEOUT"
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            switch first {
            case "\u{0}TIMEOUT":
                return "Child \"\(child)\" is still working after \(Int(timeout))s — delegation timed out, "
                     + "but it keeps running; check its transcript."
            case .some(let text) where !text.isEmpty:
                return text
            default:
                return "Child \"\(child)\" completed but returned no text."
            }
        }
    }

    // MARK: - Black Box Conversation API

    private var activeConversations: [UUID: GrokBuildConversation] = [:]
    /// Gist preambles waiting to be injected on the next conversation handshake.
    private var pendingSessionGists: [UUID: String] = [:]
    /// Instances mid role-restart / brain swap — `clearHistory` and `sendPrompt` wait here.
    private var transitionDepth: [UUID: Int] = [:]

    /// True while a role transition or `restartInstance` is in flight for this Connection.
    public func isInstanceTransitioning(_ id: UUID) -> Bool {
        (transitionDepth[id] ?? 0) > 0
    }

    private func beginTransition(_ id: UUID) {
        transitionDepth[id, default: 0] += 1
    }

    private func endTransition(_ id: UUID) {
        guard let depth = transitionDepth[id] else { return }
        if depth <= 1 { transitionDepth.removeValue(forKey: id) }
        else { transitionDepth[id] = depth - 1 }
    }

    /// Blocks until no restart/role transition is running for this instance.
    private func waitUntilReady(for id: UUID) async {
        while isInstanceTransitioning(id) {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// How a role-prompt edit should take effect. See issue #177 / `design/12`.
    public enum RoleTransitionMode: Sendable {
        /// Reset `primed` and re-inject on the next turn; keeps the live ACP session.
        case reprimeOnly
        /// Restart the Node and inject a tier-0 session gist on the first primed turn.
        case restartWithGist
        /// Restart the Node with no prior-context carry-forward.
        case restartFresh
    }

    /// Primary black-box API for the Mac app.
    /// Returns (or creates) a high-level conversation handle for an instance.
    /// This is the main thing most callers should use.
    public func conversation(for instanceID: UUID, config: ManagedInstance? = nil) async throws -> GrokBuildConversation {
        if let existing = activeConversations[instanceID] {
            return existing
        }

        if await server.getClient(for: instanceID) == nil, let cfg = config {
            _ = try await server.startInstance(cfg)
        }

        guard let client = await server.getClient(for: instanceID) else {
            throw GrokBuildError.instanceManagementError("Failed to obtain client for instance \(instanceID)")
        }

        // Let a model-agnostic (API) brain orchestrate too: install the `delegate`
        // handler, scoped to *this* Node's own children (grok Nodes get `delegate`
        // via the Orchestration MCP server instead). Same router as everything else.
        let cfg = instanceStates[instanceID] ?? config
        if let api = client as? OpenAICompatSession, let cfg {
            let catalog = ConnectionStore.loadBrainCatalog()
            let tierMap = ConnectionStore.loadTierMap()
            let fleetOrch = cfg.role == .orchestrator
                && OrchestrationSupport.mode(for: cfg.brain, catalog: catalog, tierMap: tierMap) == .orchestratedFleet
            if fleetOrch {
                await api.setDelegateHandler { [weak self] child, task, timeout in
                    guard let self else { return "orchestrator unavailable" }
                    return await self.delegate(
                        callerID: instanceID, toChildNamed: child, task: task,
                        timeout: timeout ?? 120
                    )
                }
            }
        }

        // New layout (memory: `connection-semantics`):
        //   …/Grokestrator/connections/<id>/history.json
        // ConnectionStore.historyURL migrates the legacy file if present.
        let historyURL = ConnectionStore.historyURL(for: instanceID)

        // Orient-on-read (design/13, design/14): load the project's design-oracle
        // invariants and inject them as preamble, so the agent orients on the
        // project's intent before acting. No oracle dir ⇒ nil ⇒ no-op.
        let cwd = instanceStates[instanceID]?.workingDirectory ?? config?.workingDirectory
        let orientation = cwd.flatMap { OracleLoader.orientationPreamble(projectDirectory: $0) }

        let convo = GrokBuildConversation(
            instanceID: instanceID,
            sessionID: "default",
            client: client,
            persistenceURL: historyURL,
            rolePrompt: instanceStates[instanceID]?.rolePrompt ?? config?.rolePrompt,
            orientationPreamble: orientation,
            sessionGistPreamble: consumePendingSessionGist(for: instanceID)
        )

        try await convo.loadHistoryIfAvailable()

        // Wire process death into the conversation (black box)
        await server.onInstanceDied(id: instanceID) { [weak self] id, exitCode in
            Task { await self?.handleInstanceDeath(id: id, exitCode: exitCode) }
        }

        activeConversations[instanceID] = convo
        return convo
    }

    /// Actor-isolated handler invoked when an instance's process dies.
    private func handleInstanceDeath(id: UUID, exitCode: Int32) async {
        if var inst = instanceStates[id] {
            inst.status = .crashed
            instanceStates[id] = inst
        }
        if let convo = activeConversations[id] {
            await convo.onProcessDied(exitCode: exitCode)
        }
    }

    public func flattenedHistory(for instanceID: UUID) async -> [AgentMessage]? {
        await activeConversations[instanceID]?.getFlattenedHistory()
    }

    /// Returns the current runtime state of a managed instance (including status).
    public func instanceState(for id: UUID) async -> ManagedInstance? {
        await server.currentInstanceState(for: id)
    }

    /// All currently active conversations. Most Mac app code should not need to enumerate this.
    public func allActiveConversations() -> [UUID: GrokBuildConversation] {
        activeConversations
    }

    // MARK: - High-level Black Box APIs (recommended for most of the Mac app)

    /// Fire a prompt at the underlying grok process. **Fire-and-forget** in the
    /// broadcast model — updates flow out to every subscriber of the Connection
    /// (local UI + every remote GKSC). Use `subscribe(to:)` to receive them.
    /// Returns the prompt's stable UUID so the caller can cancel later if needed.
    @discardableResult
    public func sendPrompt(to instanceID: UUID, prompt: String) async throws -> UUID {
        await waitUntilReady(for: instanceID)
        let convo = try await conversation(for: instanceID)
        return try await convo.sendPrompt(prompt)
    }

    /// Cancels the currently in-flight turn for this Connection. No-op if no
    /// conversation exists yet for the instance.
    public func cancelPrompt(for instanceID: UUID) async {
        guard let convo = activeConversations[instanceID] else { return }
        await convo.cancelCurrent()
    }

    /// Subscribe to a Connection's broadcast stream. First event is `.snapshot`
    /// of the current transcript; subsequent events are `.update`s for everything
    /// that happens going forward, regardless of which client initiated the prompt.
    public func subscribe(to instanceID: UUID) async throws -> AsyncStream<ConnectionStreamEvent> {
        let convo = try await conversation(for: instanceID)
        return await convo.subscribe()
    }

    /// Get the current conversation history for an instance (structured turns, not raw events).
    public func history(for instanceID: UUID) async -> [AgentTurn]? {
        await activeConversations[instanceID]?.getHistory()
    }

    /// Clears a Connection's chat history. The conversation broadcasts an empty
    /// snapshot to every subscriber, so all connected devices reset together.
    /// No-op if no conversation exists yet for the instance.
    public func clearHistory(for instanceID: UUID) async {
        await waitUntilReady(for: instanceID)
        guard let convo = activeConversations[instanceID] else { return }
        await convo.clearHistory()
    }

    /// Capabilities (model, MCP servers, slash commands) for an instance — for the
    /// Instance Inspector and the composer's slash-command popup.
    public func capabilities(for instanceID: UUID) async throws -> AgentCapabilities {
        let convo = try await conversation(for: instanceID)
        return try await convo.capabilities()
    }

    /// Token / context usage for an instance (inspector). Nil if no conversation
    /// has been started yet (no handshake is forced).
    public func usage(for instanceID: UUID) async -> SessionUsage? {
        guard let convo = activeConversations[instanceID] else { return nil }
        return await convo.usage()
    }

    /// Get a clean state snapshot (history + pending tool/permission counts + alive status).
    /// This is the primary observation point for the rest of the Mac app.
    public func state(for instanceID: UUID) async -> ConversationState? {
        await activeConversations[instanceID]?.currentState()
    }

    /// Grok ACP session id — used to read harness subagent lineage on disk.
    public func sessionID(for instanceID: UUID) async -> String? {
        await activeConversations[instanceID]?.sessionID
    }

    /// Returns the tool calls the agent is currently waiting on for the given instance.
    public func pendingToolCalls(for instanceID: UUID) async -> [ToolCallInfo] {
        guard let convo = activeConversations[instanceID] else { return [] }
        return await convo.pendingToolCalls()
    }

    /// Returns any permission requests the agent is waiting on.
    public func pendingPermissions(for instanceID: UUID) async -> [PermissionRequestInfo] {
        guard let convo = activeConversations[instanceID] else { return [] }
        return await convo.pendingPermissions()
    }

    /// Force persistence of conversation state for all active instances.
    public func syncAll() async throws {
        for convo in activeConversations.values {
            try await convo.sync()
        }
    }

    /// Send a tool result back through the black box for a specific instance.
    public func sendToolResult(to instanceID: UUID, toolCallId: String, result: String, isError: Bool = false) async throws {
        guard let convo = activeConversations[instanceID] else {
            throw GrokBuildError.instanceManagementError("No active conversation for \(instanceID)")
        }
        try await convo.sendToolResult(toolCallId: toolCallId, result: result, isError: isError)
    }

    /// Respond to a pending permission request.
    public func respondToPermission(for instanceID: UUID, permissionId: String, chosenOption: String) async throws {
        guard let convo = activeConversations[instanceID] else {
            throw GrokBuildError.instanceManagementError("No active conversation for \(instanceID)")
        }
        try await convo.respondToPermission(permissionId: permissionId, chosenOption: chosenOption)
    }

    /// Answer a pending user question (`_x.ai/ask_user_question`). Parallels
    /// `respondToPermission`.
    public func respondToUserQuestion(for instanceID: UUID, questionId: String, questionIndex: Int, answer: String) async throws {
        guard let convo = activeConversations[instanceID] else {
            throw GrokBuildError.instanceManagementError("No active conversation for \(instanceID)")
        }
        try await convo.respondToUserQuestion(questionId: questionId, questionIndex: questionIndex, answer: answer)
    }
}
