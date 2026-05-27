import Foundation
import GrokestratorCore

/// High-level client for talking to a single running Grok Build instance
/// using the Agent Client Protocol over stdio.
public actor GrokBuildSessionClient {
    private let handle: GrokBuildInstanceHandle
    private let reader: ACPMessageReader
    private var activeSessions: Set<String> = []
    private var requestIdCounter: UInt64 = 0
    private var pendingRequests: [String: CheckedContinuation<ACPMessage, Error>] = [:]

    private var readerTask: Task<Void, Never>?
    private var activePromptStreams: [String: AsyncStream<ACPEvent>.Continuation] = [:]

    public init(handle: GrokBuildInstanceHandle) {
        self.handle = handle
        self.reader = ACPMessageReader(dataStream: handle.stdout)
        // Start the reader once the actor is fully initialized (can't call an
        // actor-isolated method directly from a synchronous init under Swift 6).
        Task { await self.startPersistentReader() }
    }

    private func startPersistentReader() {
        readerTask = Task {
            for await message in await reader.messages() {
                await self.routeMessage(message)
            }
        }
    }

    private func routeMessage(_ message: ACPMessage) async {
        // 1. Try to satisfy a pending request/response
        if let id = message.id, let cont = pendingRequests.removeValue(forKey: id) {
            cont.resume(returning: message)
            return
        }

        // 2. Decode event and try to route it intelligently
        guard let event = decodeEvent(from: message) else { return }

        // Extract sessionId from the event when possible
        let targetSession: String? = {
            switch event {
            case .message(let e): return e.sessionId
            case .thought(let e): return e.sessionId
            case .toolCall(let e): return e.sessionId
            case .toolResult(let e): return e.sessionId
            case .permissionRequest(let e): return e.sessionId
            case .sessionUpdate(let e): return e.sessionId
            default: return nil
            }
        }()

        if let session = targetSession, let cont = activePromptStreams[session] {
            cont.yield(event)
        } else {
            // Fallback: send to any active stream (common case is a single active prompt).
            if let anyStream = activePromptStreams.values.first {
                anyStream.yield(event)
            }
        }
    }

    /// Creates a new session with the Grok Build instance.
    public func createSession(metadata: [String: String]? = nil) async throws -> String {
        let request = ACPRequest.createSession(CreateSessionRequest(metadata: metadata))
        let responseMessage = try await sendRequest(request)

        // Try to extract a real session id from the response if the agent provides one
        let sessionId: String
        if let event = decodeEvent(from: responseMessage),
           case .sessionCreated(let created) = event {
            sessionId = created.sessionId
        } else {
            sessionId = "session-\(UUID().uuidString.prefix(8))"
        }

        activeSessions.insert(sessionId)
        return sessionId
    }

    /// Sends a prompt to an active session and returns a live stream of events
    /// coming from the actual Grok Build process.
    /// The stream will continue until the agent signals completion for this turn
    /// or the session is terminated.
    public func sendPrompt(sessionId: String, prompt: String) async throws -> AsyncStream<ACPEvent> {
        guard activeSessions.contains(sessionId) else {
            throw GrokBuildError.protocolError("Session \(sessionId) does not exist")
        }

        let request = ACPRequest.prompt(PromptRequest(sessionId: sessionId, prompt: prompt))
        _ = try await sendRequest(request)

        let (stream, continuation) = AsyncStream<ACPEvent>.makeStream(bufferingPolicy: .unbounded)
        activePromptStreams[sessionId] = continuation

        // Note: The stream is intentionally left open. The caller should consume until
        // they see a natural break (e.g. a message with certain metadata or they decide to send another prompt).
        // We clean it up on terminateSession or explicit finish.

        return stream
    }

    /// Explicitly finishes the event stream for a prompt (useful when you know the turn is done).
    public func finishCurrentPrompt(for sessionId: String) {
        activePromptStreams[sessionId]?.finish()
        activePromptStreams.removeValue(forKey: sessionId)
    }

    public func terminateSession(sessionId: String) async {
        activeSessions.remove(sessionId)
        activePromptStreams[sessionId]?.finish()
        activePromptStreams.removeValue(forKey: sessionId)

        // Best-effort cancel
        let cancel = ACPRequest.cancelSession(sessionId: sessionId)
        _ = try? await sendRequest(cancel)
    }

    // MARK: - Bidirectional responses (required for real agent interactions)

    /// Send a response to a permission request from the agent.
    public func respondToPermission(permissionId: String, chosenOption: String, sessionId: String) async throws {
        // In real ACP this is usually sent as a specific response message.
        // We encode it as a tool-result style or custom response for now.
        let responsePayload = try JSONEncoder().encode([
            "permissionId": permissionId,
            "chosenOption": chosenOption
        ])
        let message = ACPMessage(type: "response", id: nil, payload: responsePayload)
        let data = try JSONEncoder().encode(message)
        let line = data + "\n".data(using: .utf8)!
        try handle.stdin.write(contentsOf: line)
    }

    /// Send the result of a tool call back to the agent (critical for real multi-turn tool use).
    public func sendToolResult(sessionId: String, toolCallId: String, result: String, isError: Bool = false) async throws {
        let toolResult = ToolResultEvent(
            sessionId: sessionId,
            toolCallId: toolCallId,
            result: result,
            isError: isError
        )
        let payload = try JSONEncoder().encode(toolResult)
        let message = ACPMessage(type: "event", id: nil, payload: payload) // or "response" depending on exact ACP
        let data = try JSONEncoder().encode(message)
        let line = data + "\n".data(using: .utf8)!
        try handle.stdin.write(contentsOf: line)
    }

    // MARK: - Private

    private func sendRequest(_ request: ACPRequest) async throws -> ACPMessage {
        let requestId = nextRequestId()
        let payload = try JSONEncoder().encode(request)
        let wireMessage = ACPMessage(type: "request", id: requestId, payload: payload)

        let data = try JSONEncoder().encode(wireMessage)
        let line = data + "\n".data(using: .utf8)!

        try handle.stdin.write(contentsOf: line)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            // Real timeout so we don't hang forever if the agent is silent
            Task {
                try? await Task.sleep(nanoseconds: 25_000_000_000) // 25 seconds
                if let cont = self.pendingRequests.removeValue(forKey: requestId) {
                    cont.resume(throwing: GrokBuildError.protocolError("Request \(requestId) timed out"))
                }
            }
        }
    }

    private func decodeEvent(from message: ACPMessage) -> ACPEvent? {
        guard message.type == "event" || message.type == "response" else { return nil }

        // TEMPORARY RAW LOGGING — helps us capture real progress/activity note shapes from actual grok build instances.
        // Look for lines starting with [RAW ACP] in the console / Xcode logs.
        // Remove or gate this before any production build.
        logRawACPMessage(message, context: "decode")

        do {
            // Known specific events (order matters a little — more common first)
            if let ev = try? JSONDecoder().decode(MessageEvent.self, from: message.payload) {
                return .message(ev)
            }
            if let ev = try? JSONDecoder().decode(ThoughtEvent.self, from: message.payload) {
                return .thought(ev)
            }
            if let ev = try? JSONDecoder().decode(ToolCallEvent.self, from: message.payload) {
                return .toolCall(ev)
            }
            if let ev = try? JSONDecoder().decode(ToolResultEvent.self, from: message.payload) {
                return .toolResult(ev)
            }
            if let ev = try? JSONDecoder().decode(PermissionRequestEvent.self, from: message.payload) {
                return .permissionRequest(ev)
            }
            if let ev = try? JSONDecoder().decode(SessionUpdateEvent.self, from: message.payload) {
                return .sessionUpdate(ev)
            }

            // NEW: Progress and activity notes (the "little notes" live updates)
            if let ev = try? JSONDecoder().decode(ProgressEvent.self, from: message.payload) {
                return .progress(ev)
            }
            if let ev = try? JSONDecoder().decode(ActivityEvent.self, from: message.payload) {
                return .activity(ev)
            }
        } catch {
            print("[GrokBuildSessionClient] Event decode error: \(error)")
        }

        // Ultimate fallback: preserve the raw payload so we don't lose anything during protocol discovery
        return .unknown(rawPayload: message.payload, typeHint: message.type)
    }

    // TEMPORARY DEBUG HELPER — raw ACP payload logging
    private func logRawACPMessage(_ message: ACPMessage, context: String) {
        guard message.type == "event" || message.type == "response" else { return }

        let payloadString: String
        if let pretty = try? JSONSerialization.jsonObject(with: message.payload),
           let prettyData = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: prettyData, encoding: .utf8) {
            payloadString = str
        } else {
            payloadString = String(data: message.payload, encoding: .utf8) ?? "<non-utf8 payload>"
        }

        print("""
        [RAW ACP EVENT - TEMP LOG] context=\(context)
        type=\(message.type) id=\(message.id ?? "nil")
        payload:
        \(payloadString)
        --- end raw ACP ---
        """)
    }

    private func nextRequestId() -> String {
        requestIdCounter += 1
        return "req-\(requestIdCounter)"
    }
}
