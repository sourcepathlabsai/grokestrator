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
}

/// Responses from the server for GrokBuildRequest messages.
public enum GrokBuildResponse: Codable, Sendable {
    case promptStarted(instanceID: UUID, promptID: UUID)
    case promptCancelled(instanceID: UUID, promptID: UUID)
    case toolResultSent
    case permissionResponseSent
    case promptState( /* TODO: richer state */ )
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
}
