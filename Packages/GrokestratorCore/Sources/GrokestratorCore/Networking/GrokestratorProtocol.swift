import Foundation

// MARK: - Grokestrator Control Protocol
//
// This is the *Grokestrator* control plane protocol (distinct from ACP which is
// per Grok Build instance). It defines the messages that flow between any client
// (Mac UI or iOS) and a Grokestrator server over the chosen transport
// (WebSocket, in-process for hybrid Mac, or future secure channel over Tailscale).
//
// The goal is a simple, explicit, versionable request/response + server-push event model.

public enum GrokestratorRequest: Codable, Sendable {
    case getServerState
    case listInstances
    case launchInstance(ManagedInstance)
    case stopInstance(id: UUID)
    case restartInstance(id: UUID)
    case sendPrompt(instanceID: UUID, conversationID: UUID?, text: String)
    case getConversations(serverID: UUID)
    case getMessages(conversationID: UUID, limit: Int?)

    /// New Grok Build domain requests (see GrokBuildRequest)
    case grokBuild(GrokBuildRequest)

    // Future: capability discovery, slash command execution, permission responses, etc.
}

public enum GrokestratorResponse: Codable, Sendable {
    case serverState(ServerState)
    case instances([ManagedInstance])
    case instanceLaunched(ManagedInstance)
    case instanceStopped(id: UUID)
    case promptSent(conversationID: UUID)
    case conversations([Conversation])
    case messages([Message])
    case error(GrokestratorError)

    /// New Grok Build domain responses
    case grokBuild(GrokBuildResponse)
}

public enum GrokestratorEvent: Codable, Sendable {
    // Server -> Client push events
    case instanceStatusChanged(ManagedInstance)
    case instancesUpdated([ManagedInstance])    // full list, sent on connect + on add/remove/status-change
    case newMessage(Message)
    case conversationUpdated(Conversation)
    case serverStateChanged(ServerState)
    case log(line: String, instanceID: UUID?)
    case error(GrokestratorError)

    /// New Grok Build domain events (streaming updates, tool requests, etc.)
    case grokBuild(GrokBuildEvent)
}

// A simple envelope for transport (can be extended with request IDs for correlation)
public struct GrokestratorMessage: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let payload: Payload

    public enum Payload: Codable, Sendable {
        case request(GrokestratorRequest)
        case response(GrokestratorResponse)
        case event(GrokestratorEvent)
    }

    public init(payload: Payload) {
        self.id = UUID()
        self.timestamp = Date()
        self.payload = payload
    }
}

// MARK: - Grok Build Domain (Control Plane)

/// Requests a client can send related to Grok Build instances on a remote server.
public enum GrokBuildRequest: Codable, Sendable {
    /// Start a new prompt on the given instance.
    case startPrompt(instanceID: UUID, prompt: String, promptID: UUID?)

    /// Cancel an in-flight prompt.
    case cancelPrompt(instanceID: UUID, promptID: UUID)

    /// Send the result of a tool call back to the agent.
    case sendToolResult(instanceID: UUID, promptID: UUID, toolCallId: String, result: String, isError: Bool)

    /// Respond to a permission request from the agent.
    case respondToPermission(instanceID: UUID, promptID: UUID, permissionId: String, chosenOption: String)

    /// Request current state for a specific prompt (pending tools, etc.).
    case getPromptState(instanceID: UUID, promptID: UUID)

    /// Ask the server for an instance's capabilities (model + MCP servers +
    /// slash commands). Used by the remote Instance Inspector / slash popup.
    case getCapabilities(instanceID: UUID)

    /// Ask the server for an instance's current token / context usage snapshot.
    case getUsage(instanceID: UUID)

    /// Subscribe to a Connection's broadcast stream — the shared-session model.
    /// Server replies with `historySnapshot` then keeps forwarding every
    /// `conversationUpdate` for this Connection, regardless of which client
    /// initiated the prompt. The client sees the same transcript GKSS itself sees.
    case subscribeToConnection(instanceID: UUID)

    /// Stop receiving broadcast events for a Connection (drops the subscription).
    case unsubscribeFromConnection(instanceID: UUID)

    /// Wipe a Connection's stored chat history. The server clears the persisted
    /// transcript and broadcasts an empty `historySnapshot` to every subscriber,
    /// so all connected devices reset their transcript together. No dedicated
    /// response — the empty snapshot is the acknowledgement.
    case clearHistory(instanceID: UUID)

    /// Fetch the bytes of a media artifact that grok saved on the host Mac, so a
    /// remote client can display it (the transcript only carries the Mac-local
    /// path, which the client can't read). `maxDimension != nil` ⇒ the server
    /// returns a downscaled thumbnail (image) or poster frame (video) bounded to
    /// that pixel size; `nil` ⇒ the full original bytes. The reply is a
    /// `mediaData` event correlated by `requestID`.
    case fetchMedia(instanceID: UUID, path: String, maxDimension: Int?, requestID: UUID)
}

/// Responses from the server for GrokBuildRequest messages.
public enum GrokBuildResponse: Codable, Sendable {
    case promptStarted(instanceID: UUID, promptID: UUID)
    case promptCancelled(instanceID: UUID, promptID: UUID)
    case toolResultSent
    case permissionResponseSent
    case promptState(instanceID: UUID, promptID: UUID, pendingToolCalls: [ToolCallInfo], pendingPermissions: [PermissionRequestInfo])
    case error(String)
}

/// Server-pushed events related to Grok Build activity.
/// These are the main way clients receive streaming updates.
public enum GrokBuildEvent: Codable, Sendable {
    /// A new incremental update in an ongoing prompt (message, progress note, tool call, etc.).
    case conversationUpdate(instanceID: UUID, promptID: UUID, update: ConversationUpdate)

    /// The prompt has finished (successfully or with final state).
    case promptCompleted(instanceID: UUID, promptID: UUID, result: PromptResult?)

    /// The underlying Grok Build process for an instance died.
    case instanceDied(instanceID: UUID, exitCode: Int32)

    /// The set of pending tool calls for a prompt has changed.
    case pendingToolCallsChanged(instanceID: UUID, promptID: UUID, calls: [ToolCallInfo])

    /// The agent is requesting a permission decision.
    case permissionRequested(instanceID: UUID, promptID: UUID, info: PermissionRequestInfo)

    /// Generic error for the prompt / instance.
    case error(instanceID: UUID?, promptID: UUID?, message: String)

    /// Server's reply to `GrokBuildRequest.getCapabilities`. Also sent unsolicited
    /// when capabilities change live (e.g. after `available_commands_update`).
    case capabilitiesUpdated(instanceID: UUID, capabilities: AgentCapabilities)

    /// Server's reply to `GrokBuildRequest.getUsage`. Also sent after each turn
    /// completes so remote clients keep an accurate Session Usage view.
    case usageUpdated(instanceID: UUID, usage: SessionUsage)

    /// One-shot snapshot of the Connection's full transcript at subscribe time.
    /// Sent immediately after `subscribeToConnection`, before any subsequent
    /// `conversationUpdate` events. Clients replay this to populate their view.
    case historySnapshot(instanceID: UUID, turns: [AgentTurn])

    /// Reply to `GrokBuildRequest.fetchMedia`, correlated by `requestID`.
    /// `data == nil` ⇒ the file was missing/unreadable or exceeded the size cap.
    case mediaData(instanceID: UUID, requestID: UUID, data: Data?, mimeType: String?)
}
