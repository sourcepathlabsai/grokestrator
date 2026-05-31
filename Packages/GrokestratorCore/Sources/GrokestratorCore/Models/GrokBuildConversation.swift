import Foundation

// MARK: - Promoted Grok Build Conversation Models
//
// These types were originally defined in the Mac-only GrokBuild layer.
// They are being promoted into GrokestratorCore so that both the server
// (Mac) and clients (iOS + Mac) can work with the same rich, structured
// representation of agent conversations.
//
// Goal: Clients should be able to consume high-fidelity ConversationUpdate
// streams and structured history without dealing with raw ACP or wire details.

/// A high-level update from a Grok Build conversation.
/// This is the primary type clients (and the Mac UI) will consume.
public enum ConversationUpdate: Sendable, Codable {
    /// The user-submitted prompt that started a new turn. Broadcast so every
    /// subscriber (any device viewing the same Connection) sees the prompt
    /// even when *another* client typed it — that's what makes shared sessions
    /// look identical on Mac and iPad.
    case userPrompt(String)

    case thought(String, metadata: [String: String]?)
    case message(String, metadata: [String: String]?)

    /// Incremental streamed text for the in-progress thought / message (live typing).
    case thoughtDelta(String)
    case messageDelta(String)

    case toolCallRequested(ToolCallInfo)
    case permissionRequested(PermissionRequestInfo)
    /// The agent is asking the user one or more structured questions
    /// (grok's `_x.ai/ask_user_question`). Parallel to `permissionRequested`.
    case userQuestionRequested(UserQuestionInfo)
    case toolResultRecorded(toolCallId: String, isError: Bool)
    case error(String)
    case turnComplete(finalAnswer: String?)
    case sessionStatus(String)

    // Granular live progress / activity notes from the agent
    case progressNote(String, phase: String?, metadata: [String: String]?)
    case activityNote(String, kind: String?, metadata: [String: String]?)

    /// Catch-all for unknown event shapes during protocol discovery / evolution
    case unknownEvent(rawJSON: String?)
}

/// Structured information about a tool the agent wants to call.
public struct ToolCallInfo: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let toolName: String
    public let arguments: [String: String]?
    public let sessionId: String?

    public init(id: String, toolName: String, arguments: [String: String]? = nil, sessionId: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.sessionId = sessionId
    }
}

/// Structured information about a permission the agent is requesting.
public struct PermissionRequestInfo: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let description: String
    public let options: [PermissionOption]
    public let sessionId: String?

    public init(id: String, description: String, options: [PermissionOption], sessionId: String? = nil) {
        self.id = id
        self.description = description
        self.options = options
        self.sessionId = sessionId
    }
}

/// One selectable answer to a permission request. `id` is the ACP `optionId`
/// sent back to the agent; `kind` is `allow_once`/`allow_always`/`reject_once`/`reject_always`.
public struct PermissionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String?

    public init(id: String, label: String, kind: String?) {
        self.id = id
        self.label = label
        self.kind = kind
    }

    public var isAllow: Bool { (kind ?? "").hasPrefix("allow") }
}

// MARK: - User Questions (grok `_x.ai/ask_user_question`)

/// Structured information about one or more questions the agent is asking the
/// user. Parallels `PermissionRequestInfo`. `id` is the pending request id used
/// to route the answer back to the agent (the suspended JSON-RPC request).
public struct UserQuestionInfo: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let questions: [UserQuestion]
    public let sessionId: String?

    public init(id: String, questions: [UserQuestion], sessionId: String? = nil) {
        self.id = id
        self.questions = questions
        self.sessionId = sessionId
    }
}

/// A single question with a set of suggested options. The user may pick one of
/// the `options` or supply free text (the "Other" path).
public struct UserQuestion: Sendable, Equatable, Codable {
    public let prompt: String
    public let options: [UserQuestionOption]

    public init(prompt: String, options: [UserQuestionOption]) {
        self.prompt = prompt
        self.options = options
    }
}

/// One suggested answer to a `UserQuestion`. `label` is the literal option text
/// (also what we send back to the agent); `description` is optional supporting
/// detail shown muted under the label.
public struct UserQuestionOption: Sendable, Equatable, Codable, Identifiable {
    public var id: String { label }
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// Result of a completed prompt turn.
public struct PromptResult: Sendable, Codable {
    public let updates: [ConversationUpdate]
    public let finalAnswer: String?
    public let turnsAdded: Int
    public let hadToolCalls: Bool
    public let hadPermissionRequests: Bool

    public init(updates: [ConversationUpdate], finalAnswer: String?, turnsAdded: Int,
                hadToolCalls: Bool, hadPermissionRequests: Bool) {
        self.updates = updates
        self.finalAnswer = finalAnswer
        self.turnsAdded = turnsAdded
        self.hadToolCalls = hadToolCalls
        self.hadPermissionRequests = hadPermissionRequests
    }
}

/// Lightweight snapshot of current conversation state.
public struct ConversationState: Sendable, Codable {
    public let instanceID: UUID
    public let sessionID: String
    public let turns: [AgentTurn]
    public let lastAssistantMessage: AgentMessage?
    public let isInActiveTurn: Bool
    public let pendingToolCallCount: Int
    public let pendingPermissionCount: Int
    public let isAlive: Bool

    public init(instanceID: UUID, sessionID: String, turns: [AgentTurn],
                lastAssistantMessage: AgentMessage?, isInActiveTurn: Bool,
                pendingToolCallCount: Int, pendingPermissionCount: Int, isAlive: Bool) {
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.turns = turns
        self.lastAssistantMessage = lastAssistantMessage
        self.isInActiveTurn = isInActiveTurn
        self.pendingToolCallCount = pendingToolCallCount
        self.pendingPermissionCount = pendingPermissionCount
        self.isAlive = isAlive
    }
}

/// One event in a Connection's broadcast stream. Every subscriber (local Mac
/// UI + every connected GKSC) receives the same sequence: a one-time
/// `.snapshot` carrying the full history at subscribe time, followed by
/// `.update` events for everything that happens from that point on,
/// **regardless of which client initiated the prompt**. That's what makes
/// GKSS the single source of truth — every viewer sees the same conversation.
public enum ConnectionStreamEvent: Sendable, Codable {
    case snapshot([AgentTurn])
    case update(ConversationUpdate)
}

// MARK: - Structured History Types

/// A message within an agent turn.
public struct AgentMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: Role
    public let content: String
    public let timestamp: Date
    public let metadata: [String: String]?

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case tool
    }

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

/// Represents one complete turn (user prompt + everything the agent produced).
public struct AgentTurn: Identifiable, Codable, Sendable {
    public let id: UUID
    public let userPrompt: String
    public let messages: [AgentMessage]
    public let timestamp: Date

    public init(userPrompt: String, messages: [AgentMessage], timestamp: Date = Date()) {
        self.id = UUID()
        self.userPrompt = userPrompt
        self.messages = messages
        self.timestamp = timestamp
    }
}
