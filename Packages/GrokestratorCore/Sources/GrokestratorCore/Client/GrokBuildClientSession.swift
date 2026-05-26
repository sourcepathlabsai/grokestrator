import Foundation

/// Higher-level client abstraction for driving a remote Grok Build instance.
///
/// This type aims to provide an experience similar to the local `GrokBuildConversation`
/// while hiding the details of the `GrokestratorProtocol` and transport layer.
///
/// Usage:
/// - Create via `GrokestratorClient` (preferred) or directly with a send closure.
/// - Call `startPrompt(...)` to drive the remote agent.
/// - Listen to the returned `AsyncStream<ConversationUpdate>`.
/// - Use `sendToolResult(...)` to continue tool-using agents.
public actor GrokBuildClientSession {
    public let instanceID: UUID

    /// Function used to send control-plane requests. Injected by the owning client.
    private let sendRequest: @Sendable (GrokestratorRequest) async throws -> Void

    private var activePrompts: [UUID: AsyncStream<ConversationUpdate>.Continuation] = [:]
    private var pendingToolCallsByPrompt: [UUID: [ToolCallInfo]] = [:]
    private var isValid = true

    // MARK: - Initialization

    /// Optional callback used to register active prompts with the parent client
    /// so that prompt-scoped events can be routed precisely.
    private let registerPrompt: (@Sendable (UUID, UUID) -> Void)?

    /// Create a session for a specific remote Grok Build instance.
    ///
    /// - Parameter instanceID: The ID of the remote instance this session talks to.
    /// - Parameter sendRequest: Closure that sends a `GrokestratorRequest` over the control plane.
    /// - Parameter registerPrompt: Optional callback so the owning `GrokestratorClient`
    ///   can maintain a `promptID → instanceID` map for accurate event routing.
    public init(
        instanceID: UUID,
        sendRequest: @escaping @Sendable (GrokestratorRequest) async throws -> Void,
        registerPrompt: (@Sendable (UUID, UUID) -> Void)? = nil
    ) {
        self.instanceID = instanceID
        self.sendRequest = sendRequest
        self.registerPrompt = registerPrompt
    }

    // MARK: - Public API

    /// Result of starting a prompt: the stable `promptID` for this turn plus the
    /// stream of `ConversationUpdate` values it will produce.
    ///
    /// The caller needs the `promptID` to later send tool results, respond to
    /// permissions, or cancel this specific prompt.
    public struct StartedPrompt: Sendable {
        public let promptID: UUID
        public let updates: AsyncStream<ConversationUpdate>
    }

    /// Starts a new prompt on the remote instance.
    /// Returns the prompt's stable `promptID` and a stream of `ConversationUpdate`
    /// values (messages, progress notes, tool calls, etc.).
    @discardableResult
    public func startPrompt(_ text: String) async throws -> StartedPrompt {
        guard isValid else {
            throw GrokestratorError.sessionInvalidated
        }

        let promptID = UUID()
        let (stream, continuation) = AsyncStream<ConversationUpdate>.makeStream(bufferingPolicy: .unbounded)

        activePrompts[promptID] = continuation
        pendingToolCallsByPrompt[promptID] = []

        let request = GrokBuildRequest.startPrompt(
            instanceID: instanceID,
            prompt: text,
            promptID: promptID
        )

        try await sendRequest(.grokBuild(request))

        // Register so the parent client can route prompt-scoped events accurately
        registerPrompt?(promptID, instanceID)

        return StartedPrompt(promptID: promptID, updates: stream)
    }

    /// Sends the result of a tool call back to the remote agent.
    public func sendToolResult(
        promptID: UUID,
        toolCallId: String,
        result: String,
        isError: Bool = false
    ) async throws {
        guard isValid else {
            throw GrokestratorError.sessionInvalidated
        }
        guard activePrompts[promptID] != nil else {
            throw GrokestratorError.protocolError("No active prompt with id \(promptID)")
        }

        // Optimistically remove from local pending list
        pendingToolCallsByPrompt[promptID]?.removeAll { $0.id == toolCallId }

        let request = GrokBuildRequest.sendToolResult(
            instanceID: instanceID,
            promptID: promptID,
            toolCallId: toolCallId,
            result: result,
            isError: isError
        )

        try await sendRequest(.grokBuild(request))
    }

    /// Cancels an in-progress prompt.
    public func cancelPrompt(promptID: UUID) async throws {
        guard let continuation = activePrompts.removeValue(forKey: promptID) else { return }

        pendingToolCallsByPrompt.removeValue(forKey: promptID)

        let request = GrokBuildRequest.cancelPrompt(
            instanceID: instanceID,
            promptID: promptID
        )

        try? await sendRequest(.grokBuild(request))
        continuation.finish()
    }

    /// Returns the currently known pending tool calls for a given prompt (best-effort).
    public func pendingToolCalls(for promptID: UUID) -> [ToolCallInfo] {
        pendingToolCallsByPrompt[promptID] ?? []
    }

    /// Requests the current state of a specific prompt from the server.
    public func getPromptState(promptID: UUID) async throws {
        guard isValid else {
            throw GrokestratorError.sessionInvalidated
        }

        let request = GrokBuildRequest.getPromptState(
            instanceID: instanceID,
            promptID: promptID
        )
        try await sendRequest(.grokBuild(request))
    }

    // MARK: - Event Handling (called by the owning client)

    /// Called by the parent `GrokestratorClient` when a `GrokBuildEvent` arrives for this instance.
    public func handle(event: GrokBuildEvent) {
        guard isValid else { return }

        switch event {
        case .conversationUpdate(let instID, let promptID, let update):
            guard instID == instanceID else { return }
            activePrompts[promptID]?.yield(update)

            if case .turnComplete = update {
                activePrompts[promptID]?.finish()
                activePrompts.removeValue(forKey: promptID)
                pendingToolCallsByPrompt.removeValue(forKey: promptID)
            }

        case .pendingToolCallsChanged(let instID, let promptID, let calls):
            guard instID == instanceID else { return }
            pendingToolCallsByPrompt[promptID] = calls

        case .promptCompleted(let instID, let promptID, _):
            guard instID == instanceID else { return }
            activePrompts[promptID]?.finish()
            activePrompts.removeValue(forKey: promptID)
            pendingToolCallsByPrompt.removeValue(forKey: promptID)

        case .instanceDied(let instID, _):
            guard instID == instanceID else { return }
            // A dead remote instance can no longer service this session at all.
            invalidate(reason: "Remote Grok Build instance died")

        default:
            break
        }
    }

    /// Called when the underlying connection or instance becomes invalid.
    public func invalidate(reason: String = "Session invalidated") {
        guard isValid else { return }
        isValid = false
        invalidateAllPrompts(reason: reason)
    }

    // MARK: - Private

    private func invalidateAllPrompts(reason: String) {
        for (_, continuation) in activePrompts {
            continuation.yield(.error(reason))
            continuation.finish()
        }
        activePrompts.removeAll()
        pendingToolCallsByPrompt.removeAll()
    }
}

