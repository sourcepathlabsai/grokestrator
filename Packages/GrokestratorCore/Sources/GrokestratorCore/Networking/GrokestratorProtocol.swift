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
}

public enum GrokestratorEvent: Codable, Sendable {
    // Server -> Client push events
    case instanceStatusChanged(ManagedInstance)
    case newMessage(Message)
    case conversationUpdated(Conversation)
    case serverStateChanged(ServerState)
    case log(line: String, instanceID: UUID?)
    case error(GrokestratorError)
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
