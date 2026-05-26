import Foundation
import GrokestratorCore

/// High-level client for talking to a single running Grok Build instance
/// using the Agent Client Protocol over stdio (or future WebSocket).
public actor GrokBuildSessionClient {
    private let handle: GrokBuildInstanceHandle
    private var activeSessions: [String: String] = [:] // sessionId -> something
    private var requestIdCounter: UInt64 = 0

    public init(handle: GrokBuildInstanceHandle) {
        self.handle = handle
    }

    /// Creates a new session with the Grok Build instance.
    public func createSession(metadata: [String: String]? = nil) async throws -> String {
        let request = ACPRequest.createSession(CreateSessionRequest(metadata: metadata))
        let response = try await sendRequest(request)

        // For now we parse a simple success. In a real implementation we would
        // decode the SessionCreatedEvent properly.
        let sessionId = "session-\(Date().timeIntervalSince1970)"
        activeSessions[sessionId] = sessionId
        return sessionId
    }

    /// Sends a prompt to an active session and returns an async stream of events.
    public func sendPrompt(sessionId: String, prompt: String) async throws -> AsyncStream<ACPEvent> {
        let request = ACPRequest.prompt(PromptRequest(sessionId: sessionId, prompt: prompt))

        // In a full implementation we would correlate request/response IDs
        // and turn the stdout stream into a stream of ACPEvent.

        let (stream, continuation) = AsyncStream<ACPEvent>.makeStream()

        // Placeholder: echo the prompt as a message for now.
        // Real implementation will parse line-delimited JSON from stdout.
        Task {
            continuation.yield(.message(MessageEvent(
                sessionId: sessionId,
                role: "user",
                content: prompt,
                metadata: nil
            )))
            // In reality we would read from handle.stdout here and decode ACPMessages
            continuation.finish()
        }

        return stream
    }

    public func terminateSession(sessionId: String) async {
        activeSessions.removeValue(forKey: sessionId)
        // Send cancel if the protocol supports it
    }

    // MARK: - Low level

    private func sendRequest(_ request: ACPRequest) async throws -> Data {
        // Encode the request as ACPMessage and write to stdin
        let payload = try JSONEncoder().encode(request)
        let message = ACPMessage(type: "request", id: nextRequestId(), payload: payload)

        let data = try JSONEncoder().encode(message)
        let line = data + "\n".data(using: .utf8)!

        try handle.stdin.write(contentsOf: line)

        // TODO: Properly read and correlate the response from stdout.
        // For the initial plumbing we return empty data.
        return Data()
    }

    private func nextRequestId() -> String {
        requestIdCounter += 1
        return "req-\(requestIdCounter)"
    }
}
