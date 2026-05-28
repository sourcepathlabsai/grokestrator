import Foundation
import GrokestratorCore

// MARK: - High-level Black Box Types (public API - no ACP leakage)
//
// `ConversationUpdate`, `ToolCallInfo`, `PermissionRequestInfo`, `PermissionOption`,
// `PromptResult`, and `ConversationState` were previously duplicated here. They
// now live in GrokestratorCore (the canonical home, since they cross the wire
// when driving instances remotely) — the dedup PROJECT_STATE flagged is done.

/// The primary black-box object for interacting with a single Grok Build instance.
///
/// A caller should obtain one of these via `GrokBuildManager` and then treat it as
/// a finished communication channel. It hides all ACP details, maintains history,
/// and provides ergonomic APIs for prompts and state.
public actor GrokBuildConversation {
    public let instanceID: UUID
    public let sessionID: String

    private let client: GrokBuildSessionClient
    private let history: AgentConversationHistory

    // High-level pending state (tracked so callers never need to parse raw events)
    private var pendingToolCalls: [String: ToolCallInfo] = [:]
    private var pendingPermissions: [String: PermissionRequestInfo] = [:]
    private var lastFinalAnswer: String?
    private var primed = false

    /// Active broadcast subscribers (local Mac UI + every remote GKSC subscribed
    /// to this Connection). Each receives a `.snapshot` on join, then `.update`
    /// for every `ConversationUpdate` the conversation produces — regardless of
    /// which client initiated the prompt. This is the "GKSS is the source of
    /// truth" plumbing (see `connection-semantics`).
    private var subscribers: [UUID: AsyncStream<ConnectionStreamEvent>.Continuation] = [:]

    /// One-time priming instruction so the agent emits a machine-readable choices
    /// block we can render as buttons. Sent (hidden) ahead of the first prompt only;
    /// the user's prompt is recorded/displayed unchanged.
    private static let choicesInstruction = """
    [Grokestrator UI note] When you ask me to pick among discrete options, append \
    on its own line a block: [[CHOICES: option one | option two | ...]] using the \
    literal option labels (keep your normal message too). Omit it when there are no \
    discrete choices to pick.
    """

    public init(instanceID: UUID, sessionID: String, client: GrokBuildSessionClient, persistenceURL: URL? = nil) {
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.client = client
        self.history = AgentConversationHistory(persistenceURL: persistenceURL)
    }

    /// Call after construction to load any previously persisted history.
    public func loadHistoryIfAvailable() async throws {
        try await history.load()
    }

    /// The instance's capabilities (model, MCP servers, slash commands) for the
    /// Instance Inspector / slash-command popup. Triggers init+session if needed.
    public func capabilities() async throws -> AgentCapabilities {
        try await client.currentCapabilities()
    }

    /// Token / context usage for the session (for the inspector). Does not force a
    /// handshake — returns zeros until the first turn has reported usage.
    public func usage() async -> SessionUsage {
        await client.currentUsage()
    }

    // MARK: - Public Black-Box API (no raw ACP leakage to callers)

    /// Subscribe to this Connection's broadcast stream — every update for the
    /// conversation, regardless of which client initiates the prompt. First
    /// event is always a `.snapshot` of the current history.
    ///
    /// The local Mac UI and every remote GKSC subscriber consume the same stream
    /// shape; they're indistinguishable from the conversation's point of view.
    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        let (stream, continuation) = AsyncStream<ConnectionStreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let token = UUID()
        subscribers[token] = continuation
        // Snapshot first so the subscriber can replay before any live updates land.
        let turns = await history.turns
        continuation.yield(.snapshot(turns))
        // If the subscriber stream is dropped (UI gone), clean ourselves up.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        return stream
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    /// Fans an update out to every broadcast subscriber. The `.turnComplete`
    /// signal that used to terminate per-prompt streams now just rides through
    /// — subscriptions are open-ended and survive turn boundaries.
    private func broadcast(_ update: ConversationUpdate) {
        for (_, cont) in subscribers { cont.yield(.update(update)) }
    }

    /// Send a prompt through the black box. **Fire-and-forget** in the new
    /// broadcast model: updates flow out to every subscriber, including the
    /// caller (which is expected to have its own `subscribe()` running).
    /// Returns the prompt's stable UUID so callers can later cancel.
    @discardableResult
    public func sendPrompt(_ prompt: String) async throws -> UUID {
        // Prepare history for the new turn (idempotent if previous was finished).
        // We deliberately do NOT call `history.load()` here:
        //   - history was already loaded at conversation creation;
        //   - re-loading overwrites `turns` with disk state, which can lose any
        //     in-memory turn `startNewTurn` just finalized but hasn't saved;
        //   - on a large history the file parse stalls this actor for visible
        //     time, delaying the `.userPrompt` broadcast below (and making the
        //     UI look frozen while we're really just re-reading what we already
        //     had). Confirmed via a slow-Grokestrator-connection bug report.
        await history.startNewTurn(prompt: prompt)
        // Broadcast the prompt so every subscriber records it — including the
        // Mac UI watching a Connection driven from another device.
        broadcast(.userPrompt(prompt))

        // This is the only place that talks to the raw ACP client. On the first
        // turn, prime the agent with the choices convention (hidden from history/UI).
        let wireText = primed ? prompt : "\(Self.choicesInstruction)\n\n\(prompt)"
        primed = true
        let rawStream = try await client.sendPrompt(sessionId: sessionID, prompt: wireText)
        let promptID = UUID()

        Task { [weak self] in
            guard let self else { return }
            for await raw in rawStream {
                let update = await self.process(raw)
                await self.broadcast(update)
            }
            let final = await self.finalizeTurn()
            await self.broadcast(.turnComplete(finalAnswer: final))
        }
        return promptID
    }

    /// Processes one raw ACP event on the actor: records history, maps it to a
    /// high-level update, tracks pending items, and auto-persists meaningful events.
    private func process(_ raw: ACPEvent) async -> ConversationUpdate {
        // Always feed the internal structured history (ACP stays inside the black box)
        await history.appendEvent(raw)

        let update = mapToConversationUpdate(raw)

        // Track pending items so pendingToolCalls() and currentState() are truthful
        trackPending(from: raw)

        // Aggressive auto-persist on meaningful events
        switch raw {
        case .message, .toolCall, .permissionRequest:
            try? await history.save()
        default:
            break
        }

        // Capture a simple final answer heuristic for convenience APIs:
        // the last assistant message is a reasonable "final" for many agents.
        if case .message(let m) = raw, (m.metadata?["final"] != nil || m.role == "assistant") {
            lastFinalAnswer = m.content
        }

        return update
    }

    /// Finalizes the current turn on the actor and returns the captured final answer.
    private func finalizeTurn() async -> String? {
        await history.finishCurrentTurn()
        try? await history.save()

        let final = lastFinalAnswer

        // Clear any tool/permission expectations for this turn.
        pendingToolCalls.removeAll()
        pendingPermissions.removeAll()

        return final
    }

    // `sendPromptAndCollect` was removed when the per-prompt stream went away
    // (broadcast model — see `subscribe()`). External callers should subscribe
    // and consume `.snapshot` + `.update` events directly.

    // Internal mapper – keeps ACP knowledge encapsulated inside the black box
    private func mapToConversationUpdate(_ event: ACPEvent) -> ConversationUpdate {
        switch event {
        case .thought(let t):
            return .thought(t.content, metadata: t.metadata)
        case .message(let m):
            return .message(m.content, metadata: m.metadata)
        case .thoughtDelta(let s):
            return .thoughtDelta(s)
        case .messageDelta(let s):
            return .messageDelta(s)
        case .toolCall(let t):
            let info = ToolCallInfo(
                id: t.toolCallId,
                toolName: t.toolName,
                arguments: t.arguments,
                sessionId: t.sessionId
            )
            return .toolCallRequested(info)
        case .permissionRequest(let p):
            let info = PermissionRequestInfo(
                id: p.permissionId,
                description: p.description,
                options: p.options,
                sessionId: p.sessionId
            )
            return .permissionRequested(info)
        case .toolResult(let t):
            return .toolResultRecorded(toolCallId: t.toolCallId, isError: t.isError)
        case .sessionUpdate(let u):
            return .sessionStatus(u.status)
        case .error(let e):
            return .error(e.message)
        case .sessionCreated, .done:
            return .sessionStatus("session event")

        // NEW: Live progress and activity notes from the real agent
        case .progress(let p):
            return .progressNote(p.content, phase: p.phase, metadata: p.metadata)
        case .activity(let a):
            return .activityNote(a.note, kind: a.kind, metadata: a.metadata)

        case .unknown(let rawPayload, let typeHint):
            let rawJSON = String(data: rawPayload, encoding: .utf8)
            print("[GrokBuildConversation] Saw unknown ACP event shape (typeHint=\(typeHint ?? "nil")). Raw preserved for debugging.")
            return .unknownEvent(rawJSON: rawJSON)
        }
    }

    private func trackPending(from event: ACPEvent) {
        switch event {
        case .toolCall(let t):
            let info = ToolCallInfo(
                id: t.toolCallId,
                toolName: t.toolName,
                arguments: t.arguments,
                sessionId: t.sessionId
            )
            pendingToolCalls[t.toolCallId] = info

        case .permissionRequest(let p):
            let info = PermissionRequestInfo(
                id: p.permissionId,
                description: p.description,
                options: p.options,
                sessionId: p.sessionId
            )
            pendingPermissions[p.permissionId] = info

        case .toolResult(let t):
            pendingToolCalls.removeValue(forKey: t.toolCallId)

        default:
            break
        }
    }

    // MARK: - History & State (the "get data about the instance" part)

    public func getHistory() async -> [AgentTurn] {
        await history.turns
    }

    public func getFlattenedHistory() async -> [AgentMessage] {
        await history.flattenedHistory()
    }

    public func isInActiveTurn() async -> Bool {
        await history.isInActiveTurn
    }

    /// Whether the underlying process is still alive.
    public private(set) var isAlive: Bool = true


    /// Force-finish the current turn (useful when the agent is done).
    public func finishCurrentTurn() async {
        await history.finishCurrentTurn()
        await client.finishCurrentPrompt(for: sessionID)
    }

    // MARK: - Bidirectional (tool results, permissions) - ergonomic black box surface

    public func sendToolResult(toolCallId: String, result: String, isError: Bool = false) async throws {
        // Clear our tracked pending state first (so currentState() reflects reality immediately)
        pendingToolCalls.removeValue(forKey: toolCallId)

        try await client.sendToolResult(
            sessionId: sessionID,
            toolCallId: toolCallId,
            result: result,
            isError: isError
        )

        // Record in history as well
        await history.appendEvent(.toolResult(ToolResultEvent(
            sessionId: sessionID,
            toolCallId: toolCallId,
            result: result,
            isError: isError
        )))
        try? await history.save()
    }

    public func respondToPermission(permissionId: String, chosenOption: String) async throws {
        pendingPermissions.removeValue(forKey: permissionId)

        try await client.respondToPermission(
            permissionId: permissionId,
            chosenOption: chosenOption,
            sessionId: sessionID
        )
    }

    /// Returns the last assistant-visible message (useful for UI).
    public func lastAssistantMessage() async -> AgentMessage? {
        let flat = await history.flattenedHistory()
        return flat.last { $0.role == .assistant }
    }

    /// Force a persistence sync (useful before app quit or for explicit checkpoints).
    public func sync() async throws {
        try await history.save()
    }

    // MARK: - Lifecycle & Robustness

    private let (deathStream, deathContinuation) = AsyncStream<Void>.makeStream()

    /// Called internally when the underlying process dies.
    internal func onProcessDied(exitCode: Int32) {
        isAlive = false
        // Emit a high-level error update if anyone is still listening to active streams
        // (the per-prompt streams will naturally end; callers watching onDied get the signal)
        print("[GrokBuildConversation] Underlying process for \(instanceID) died with code \(exitCode)")
        deathContinuation.yield(())
        deathContinuation.finish()
    }

    /// Stream that fires when the underlying Grok Build process dies.
    /// The Mac app can observe this to show errors or offer to restart the instance.
    public var onDied: AsyncStream<Void> {
        deathStream
    }

    // MARK: - Higher-level Agent Loop Support (true black box ergonomics)

    /// Returns the currently pending tool calls that the agent has requested but not yet received results for.
    /// This is the primary way for a caller to know what it needs to do next without parsing events.
    public func pendingToolCalls() async -> [ToolCallInfo] {
        Array(pendingToolCalls.values)
    }

    /// Returns any currently pending permission requests.
    public func pendingPermissions() async -> [PermissionRequestInfo] {
        Array(pendingPermissions.values)
    }

    /// Send multiple tool results at once (common after parallel tool use).
    public func sendToolResults(_ results: [(toolCallId: String, result: String, isError: Bool)]) async throws {
        for r in results {
            try await sendToolResult(toolCallId: r.toolCallId, result: r.result, isError: r.isError)
        }
    }

    /// Returns a snapshot of the current conversation state.
    /// This is the main thing the Mac app UI / ServerState should query.
    public func currentState() async -> ConversationState {
        let turns = await history.turns
        let flat = await history.flattenedHistory()
        let lastAssistant = flat.last { $0.role == .assistant }

        return ConversationState(
            instanceID: instanceID,
            sessionID: sessionID,
            turns: turns,
            lastAssistantMessage: lastAssistant,
            isInActiveTurn: await history.isInActiveTurn,
            pendingToolCallCount: pendingToolCalls.count,
            pendingPermissionCount: pendingPermissions.count,
            isAlive: isAlive
        )
    }
}

