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

    /// Returns the current view of all managed instances (suitable for updating ServerState).
    public func currentInstances() -> [ManagedInstance] {
        Array(instanceStates.values)
    }

    /// Advanced escape hatch. Most Mac app code should never call this.
    internal func _client(for id: UUID) -> GrokBuildSessionClient? {
        server.getClient(for: id)
    }

    /// Lower-level escape hatch that still leaks ACP details.
    /// Most Mac app code should use `conversation(for:)` + the high-level sendPrompt on the conversation instead.
    /// Only for advanced debugging or when you genuinely need the raw ACP stream.
    public func runPrompt(on instanceID: UUID, prompt: String) async throws -> (sessionId: String, events: AsyncStream<ACPEvent>) {
        guard let client = server.getClient(for: instanceID) else {
            throw GrokBuildError.instanceManagementError("No active client for instance \(instanceID)")
        }
        let sessionId = try await client.createSession()
        let events = try await client.sendPrompt(sessionId: sessionId, prompt: prompt)
        return (sessionId, events)
    }

    /// Restores conversations for all currently running instances (called on app launch / server restart).
    public func restoreActiveConversations() async throws {
        let running = server.listRunningInstances()
        for inst in running {
            _ = try? await conversation(for: inst.id)
        }
    }

    // MARK: - Black Box Conversation API

    private var activeConversations: [UUID: GrokBuildConversation] = [:]

    /// Primary black-box API for the Mac app.
    /// Returns (or creates) a high-level conversation handle for an instance.
    /// This is the main thing most callers should use.
    public func conversation(for instanceID: UUID, config: ManagedInstance? = nil) async throws -> GrokBuildConversation {
        if let existing = activeConversations[instanceID] {
            return existing
        }

        if server.getClient(for: instanceID) == nil, let cfg = config {
            _ = try await server.startInstance(cfg)
        }

        guard let client = server.getClient(for: instanceID) else {
            throw GrokBuildError.instanceManagementError("Failed to obtain client for instance \(instanceID)")
        }

        let convosDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grokestrator", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        let historyURL = convosDir.appendingPathComponent("\(instanceID.uuidString).json")

        let convo = GrokBuildConversation(
            instanceID: instanceID,
            sessionID: "default",
            client: client,
            persistenceURL: historyURL
        )

        try await convo.loadHistoryIfAvailable()

        // Wire process death into the conversation (black box)
        server.onInstanceDied(id: instanceID) { [weak self] id, exitCode in
            Task { [weak self] in
                guard let self = self else { return }
                if var inst = self.instanceStates[id] {
                    inst.status = .crashed
                    self.instanceStates[id] = inst
                }
                if let convo = self.activeConversations[id] {
                    await convo.onProcessDied(exitCode: exitCode)
                }
            }
        }

        activeConversations[instanceID] = convo
        return convo
    }

    public func flattenedHistory(for instanceID: UUID) async -> [AgentMessage]? {
        await activeConversations[instanceID]?.getFlattenedHistory()
    }

    /// Returns the current runtime state of a managed instance (including status).
    public func instanceState(for id: UUID) -> ManagedInstance? {
        server.currentInstanceState(for: id)
    }

    /// All currently active conversations. Most Mac app code should not need to enumerate this.
    public func activeConversations() -> [UUID: GrokBuildConversation] {
        activeConversations
    }

    // MARK: - High-level Black Box APIs (recommended for most of the Mac app)

    /// Send a prompt through the black box. Returns high-level ConversationUpdate stream.
    /// Callers (UI, etc.) never need to know about ACP, ToolCallEvent, or the protocol.
    public func sendPrompt(to instanceID: UUID, prompt: String) async throws -> AsyncStream<ConversationUpdate> {
        let convo = try await conversation(for: instanceID)
        return try await convo.sendPrompt(prompt)
    }

    /// Send a prompt and receive a rich, structured result with all updates and outcome info.
    public func sendPromptAndCollect(to instanceID: UUID, prompt: String) async throws -> PromptResult {
        let convo = try await conversation(for: instanceID)
        return try await convo.sendPromptAndCollect(prompt)
    }

    /// Get the current conversation history for an instance (structured turns, not raw events).
    public func history(for instanceID: UUID) async -> [AgentTurn]? {
        await activeConversations[instanceID]?.getHistory()
    }

    /// Get a clean state snapshot (history + pending tool/permission counts + alive status).
    /// This is the primary observation point for the rest of the Mac app.
    public func state(for instanceID: UUID) async -> ConversationState? {
        await activeConversations[instanceID]?.currentState()
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
}
