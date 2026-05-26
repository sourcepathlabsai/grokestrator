import Foundation

// MARK: - Agent Client Protocol (ACP) for Grok Build
//
// This is the protocol used to communicate with running Grok Build instances.
// It is distinct from Grokestrator's internal control plane (GrokestratorProtocol).
//
// When launching a Grok instance with appropriate flags (e.g. `grok agent serve --stdio`),
// it speaks this protocol over stdin/stdout.

public enum ACPRequest: Codable, Sendable {
    case createSession(CreateSessionRequest)
    case prompt(PromptRequest)
    case cancelSession(sessionId: String)
    // Add more as we discover the full protocol (tool call responses, etc.)
}

public struct CreateSessionRequest: Codable, Sendable {
    public let sessionId: String?
    public let metadata: [String: String]?

    public init(sessionId: String? = nil, metadata: [String: String]? = nil) {
        self.sessionId = sessionId
        self.metadata = metadata
    }
}

public struct PromptRequest: Codable, Sendable {
    public let sessionId: String
    public let prompt: String
    public let context: [String: String]?

    public init(sessionId: String, prompt: String, context: [String: String]? = nil) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.context = context
    }
}

public enum ACPEvent: Codable, Sendable {
    case sessionCreated(SessionCreatedEvent)
    case message(MessageEvent)
    case thought(ThoughtEvent)
    case toolCall(ToolCallEvent)
    case toolResult(ToolResultEvent)
    case permissionRequest(PermissionRequestEvent)
    case sessionUpdate(SessionUpdateEvent)
    case error(ACPErrorEvent)
    case done(sessionId: String)
}

public struct SessionCreatedEvent: Codable, Sendable {
    public let sessionId: String
    public let capabilities: [String]?
}

public struct MessageEvent: Codable, Sendable {
    public let sessionId: String
    public let role: String // "assistant", "user", etc.
    public let content: String
    public let metadata: [String: String]?
}

public struct ThoughtEvent: Codable, Sendable {
    public let sessionId: String
    public let content: String
    public let metadata: [String: String]?
}

public struct ToolCallEvent: Codable, Sendable {
    public let sessionId: String
    public let toolCallId: String
    public let toolName: String
    public let arguments: [String: String]?
}

public struct ToolResultEvent: Codable, Sendable {
    public let sessionId: String
    public let toolCallId: String
    public let result: String
    public let isError: Bool
}

public struct PermissionRequestEvent: Codable, Sendable {
    public let sessionId: String
    public let permissionId: String
    public let description: String
    public let options: [String]
}

public struct SessionUpdateEvent: Codable, Sendable {
    public let sessionId: String
    public let status: String
    public let metadata: [String: String]?
}

public struct ACPErrorEvent: Codable, Sendable {
    public let sessionId: String?
    public let code: String
    public let message: String
}

// MARK: - Wire Format

/// Simple line-delimited JSON protocol wrapper commonly used for ACP/stdio agents.
public struct ACPMessage: Codable, Sendable {
    public let type: String // "request", "event", "response"
    public let id: String?
    public let payload: Data // The actual request or event encoded as JSON

    public init(type: String, id: String? = nil, payload: Data) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}
