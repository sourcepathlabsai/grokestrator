import Foundation
import GrokestratorCore

/// Drives a Connection that lives on a *remote* Grokestrator server, reachable
/// over Tailscale. Wraps a `GrokBuildClientSession` so the UI's
/// `ConversationDriver` seam works identically for local and remote.
///
/// **Broadcast model (PR B):** `send` is fire-and-forget; updates flow back via
/// `subscribe()`, including the `.snapshot` of existing history. That's what
/// makes "pick up iPad → see the same transcript as the Mac" work.
public final class RemoteConversationDriver: ConversationDriver, @unchecked Sendable {
    private let session: GrokBuildClientSession
    /// Base URL of the host's media HTTP server (e.g. http://192.168.1.212:7848),
    /// used to build streamable URLs for video/audio. nil ⇒ media URLs unavailable.
    private let mediaBaseURL: URL?
    /// Most recent prompt id, so `respondToPermission` can address its turn.
    private var lastPromptID: UUID?

    public init(session: GrokBuildClientSession, mediaBaseURL: URL? = nil) {
        self.session = session
        self.mediaBaseURL = mediaBaseURL
    }

    public func send(_ prompt: String) async throws {
        lastPromptID = try await session.startPrompt(prompt)
    }

    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        await session.subscribe()
    }

    public func respondToPermission(permissionId: String, optionId: String) async {
        guard let promptID = lastPromptID else { return }
        try? await session.respondToPermission(promptID: promptID,
                                               permissionId: permissionId,
                                               chosenOption: optionId)
    }

    public func respondToUserQuestion(questionId: String, questionIndex: Int, answer: String) async {
        guard let promptID = lastPromptID else { return }
        try? await session.respondToUserQuestion(promptID: promptID,
                                                 questionId: questionId,
                                                 questionIndex: questionIndex,
                                                 answer: answer)
    }

    public func cancel() async {
        // Stop the connection's CURRENT turn — even one this client didn't start.
        // In the broadcast model a turn is often driven from the host or another
        // device, so `lastPromptID` (set only by *our own* `send`) is nil; gating
        // on it made Stop a silent no-op for those turns. The host ignores the
        // promptID anyway and cancels whatever turn is in flight
        // (see `MacGrokestratorServer`'s `.cancelPrompt` → `manager.cancelPrompt`),
        // so pass `lastPromptID` if we have it, else a throwaway id.
        try? await session.cancelPrompt(promptID: lastPromptID ?? UUID())
    }

    public func capabilities() async -> AgentCapabilities? {
        await session.getCapabilities()
    }

    public func usage() async -> SessionUsage? {
        await session.getUsage()
    }

    public func clearHistory() async {
        try? await session.clearHistory()
    }

    // Remote host: artifacts live on the other machine; fetch them over the wire.
    public var resolvesMediaRemotely: Bool { true }

    public func fetchMediaThumbnail(path: String, maxDimension: Int) async -> (data: Data, mimeType: String)? {
        await session.fetchThumbnail(path: path, maxDimension: maxDimension)
    }

    public func fetchMediaFile(path: String) async -> (url: URL, mimeType: String)? {
        await session.fetchFullFile(path: path)
    }

    public func mediaURL(forHostPath path: String) -> URL? {
        guard var c = mediaBaseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        c.path = "/media"
        c.queryItems = [URLQueryItem(name: "path", value: path)]   // URLComponents percent-encodes the value
        return c.url
    }
}
