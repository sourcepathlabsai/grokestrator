import Foundation

/// A clean, high-level representation of a conversation with a Grok Build instance.
/// This is what the rest of the app should use instead of raw ACP events.
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

/// Represents one turn in the conversation (user prompt + everything the agent produced in response).
public struct AgentTurn: Identifiable, Codable, Sendable {
    public let id: UUID
    public let userPrompt: String
    public let messages: [AgentMessage]   // thoughts, final messages, tool calls, etc.
    public let timestamp: Date

    public init(userPrompt: String, messages: [AgentMessage], timestamp: Date = Date()) {
        self.id = UUID()
        self.userPrompt = userPrompt
        self.messages = messages
        self.timestamp = timestamp
    }
}

/// Maintains the full conversation history for one session with a Grok Build instance.
/// This is the "black box" state that callers can query.
/// 
/// Supports persistence so history survives app restarts (sync).
public actor AgentConversationHistory {
    private(set) public var turns: [AgentTurn] = []
    private var currentTurnMessages: [AgentMessage] = []
    private var currentPrompt: String?

    private let persistenceURL: URL?

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
    }

    /// Loads persisted history if a persistence URL was provided.
    public func load() async throws {
        guard let url = persistenceURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let loaded = try JSONDecoder().decode([AgentTurn].self, from: data)
        self.turns = loaded
    }

    /// Persists the current history (for sync / restart resilience).
    public func save() async throws {
        guard let url = persistenceURL else { return }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(turns)
        try data.write(to: url, options: .atomic)
    }

    /// Call when the user sends a new prompt.
    public func startNewTurn(prompt: String) {
        if !currentTurnMessages.isEmpty || currentPrompt != nil {
            finishCurrentTurn()
        }
        currentPrompt = prompt
        currentTurnMessages = []
    }

    /// Add a raw event from the ACP layer into the history.
    public func appendEvent(_ event: ACPEvent) {
        switch event {
        case .message(let m):
            let role: AgentMessage.Role = (m.role == "user") ? .user : .assistant
            currentTurnMessages.append(AgentMessage(role: role, content: m.content, metadata: m.metadata))

        case .thought(let t):
            currentTurnMessages.append(AgentMessage(role: .assistant, content: "[thought] \(t.content)", metadata: t.metadata))

        case .toolCall(let t):
            let content = "Tool call: \(t.toolName) \(t.arguments ?? [:])"
            currentTurnMessages.append(AgentMessage(role: .tool, content: content, metadata: ["toolCallId": t.toolCallId]))

        case .toolResult(let t):
            currentTurnMessages.append(AgentMessage(role: .tool, content: t.result, metadata: ["toolCallId": t.toolCallId, "isError": "\(t.isError)"]))

        case .permissionRequest(let p):
            currentTurnMessages.append(AgentMessage(role: .system, content: "Permission requested: \(p.description)"))

        case .sessionUpdate, .sessionCreated, .done:
            break

        case .error(let e):
            currentTurnMessages.append(AgentMessage(role: .system, content: "[error] \(e.message)"))

        // Progress and activity notes — record them so they survive restarts and appear in history
        case .progress(let p):
            let phase = p.phase.map { "[\($0)] " } ?? ""
            currentTurnMessages.append(AgentMessage(role: .assistant, content: "\(phase)\(p.content)", metadata: p.metadata))

        case .activity(let a):
            let kind = a.kind.map { "[\($0)] " } ?? ""
            currentTurnMessages.append(AgentMessage(role: .assistant, content: "\(kind)\(a.note)", metadata: a.metadata))

        case .unknown(let rawPayload, let typeHint):
            // Best-effort: store a short marker + the raw if it's small
            let preview = String(data: rawPayload.prefix(200), encoding: .utf8) ?? "<binary>"
            currentTurnMessages.append(AgentMessage(
                role: .system,
                content: "[unknown ACP event: \(typeHint ?? "n/a")] \(preview)",
                metadata: ["rawLength": "\(rawPayload.count)"]
            ))
        }
    }

    /// Call when the current agent turn is complete.
    public func finishCurrentTurn() {
        guard let prompt = currentPrompt else { return }

        let turn = AgentTurn(userPrompt: prompt, messages: currentTurnMessages)
        turns.append(turn)

        currentPrompt = nil
        currentTurnMessages = []
    }

    /// Returns a flattened view of the entire conversation as messages.
    public func flattenedHistory() -> [AgentMessage] {
        var all: [AgentMessage] = []
        for turn in turns {
            all.append(AgentMessage(role: .user, content: turn.userPrompt))
            all.append(contentsOf: turn.messages)
        }
        return all
    }

    public var isInActiveTurn: Bool {
        currentPrompt != nil
    }
}
