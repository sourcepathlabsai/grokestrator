import Foundation
import GrokestratorCore

// MARK: - High-level Black Box Types (public API - no ACP leakage)

/// A high-level update from a Grok Build conversation.
/// Callers (Mac app UI, ServerState, etc.) consume this instead of raw ACP events.
///
/// This now includes the live "little progress notes" that real Grok Build instances emit
/// during thinking, tool use, searching, etc.
public enum ConversationUpdate: Sendable {
    case thought(String, metadata: [String: String]?)
    case message(String, metadata: [String: String]?)
    case toolCallRequested(ToolCallInfo)
    case permissionRequested(PermissionRequestInfo)
    case toolResultRecorded(toolCallId: String, isError: Bool)
    case error(String)
    case turnComplete(finalAnswer: String?)
    case sessionStatus(String)

    // The granular live progress / activity notes from the agent ("Searching...", "Analyzing...", etc.)
    case progressNote(String, phase: String?, metadata: [String: String]?)
    case activityNote(String, kind: String?, metadata: [String: String]?)

    /// We received an event shape we don't fully understand yet (from the .unknown fallback).
    /// The raw JSON is included so the Mac app (or a debug view) can still display or log it.
    case unknownEvent(rawJSON: String?)
}

/// Structured information about a tool the agent wants to call.
/// The caller uses this (or the id) to decide whether to approve and what result to supply.
public struct ToolCallInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let toolName: String
    public let arguments: [String: String]?
    public let sessionId: String?
}

/// Structured information about a permission the agent is requesting.
public struct PermissionRequestInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let description: String
    public let options: [String]
    public let sessionId: String?
}

/// Result of a completed prompt turn through the black box.
public struct PromptResult: Sendable {
    public let updates: [ConversationUpdate]
    public let finalAnswer: String?
    public let turnsAdded: Int
    public let hadToolCalls: Bool
    public let hadPermissionRequests: Bool
}

/// Lightweight snapshot for the rest of the Mac app (already existed, now enriched).
public struct ConversationState: Sendable {
    public let instanceID: UUID
    public let sessionID: String
    public let turns: [AgentTurn]
    public let lastAssistantMessage: AgentMessage?
    public let isInActiveTurn: Bool
    public let pendingToolCallCount: Int
    public let pendingPermissionCount: Int
    public let isAlive: Bool
}

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

    // MARK: - Public Black-Box API (no raw ACP leakage to callers)

    /// Send a prompt through the black box.
    /// Returns a stream of high-level ConversationUpdate values.
    /// The caller does not need to know anything about ACP, request IDs, or wire details.
    /// History is automatically accumulated, turn tracking is updated, and persistence is triggered.
    public func sendPrompt(_ prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        // Prepare history for the new turn (idempotent if previous was finished)
        await history.startNewTurn(prompt: prompt)
        try? await history.load()

        // This is the only place that talks to the raw ACP client
        let rawStream = try await client.sendPrompt(sessionId: sessionID, prompt: prompt)

        let (wrapped, continuation) = AsyncStream<ConversationUpdate>.makeStream(bufferingPolicy: .unbounded)

        // Capture self weakly for the task. All actor state is touched through
        // isolated helpers (`process(_:)` / `finalizeTurn()`) so the loop stays
        // off the actor while still mutating state safely.
        Task { [weak self] in
            guard let self = self else {
                continuation.finish()
                return
            }

            for await raw in rawStream {
                let update = await self.process(raw)
                continuation.yield(update)
            }

            // Turn is complete from the agent's perspective.
            let final = await self.finalizeTurn()
            continuation.yield(.turnComplete(finalAnswer: final))
            continuation.finish()
        }

        return wrapped
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

    /// Send a prompt and collect the full set of updates plus a synthesized result.
    /// This is the ergonomic "fire and get structured outcome" path for most callers.
    public func sendPromptAndCollect(_ prompt: String) async throws -> PromptResult {
        let stream = try await sendPrompt(prompt)
        var updates: [ConversationUpdate] = []
        var finalAnswer: String?
        var hadTool = false
        var hadPerm = false

        for await u in stream {
            updates.append(u)
            switch u {
            case .turnComplete(let ans):
                finalAnswer = ans
            case .toolCallRequested:
                hadTool = true
            case .permissionRequested:
                hadPerm = true
            default:
                break
            }
        }

        let turns = await history.turns
        let added = max(0, turns.count - (turns.count - 1)) // simplistic; real count diff not critical here

        return PromptResult(
            updates: updates,
            finalAnswer: finalAnswer ?? lastFinalAnswer,
            turnsAdded: 1,
            hadToolCalls: hadTool,
            hadPermissionRequests: hadPerm
        )
    }

    // Internal mapper – keeps ACP knowledge encapsulated inside the black box
    private func mapToConversationUpdate(_ event: ACPEvent) -> ConversationUpdate {
        switch event {
        case .thought(let t):
            return .thought(t.content, metadata: t.metadata)
        case .message(let m):
            return .message(m.content, metadata: m.metadata)
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

