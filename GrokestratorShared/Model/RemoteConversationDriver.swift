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
    /// Most recent prompt id, so `respondToPermission` can address its turn.
    private var lastPromptID: UUID?

    public init(session: GrokBuildClientSession) {
        self.session = session
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

    public func cancel() async {
        guard let promptID = lastPromptID else { return }
        // The wire's `cancelPrompt(instanceID:promptID:)` already existed; the
        // server (MacGrokestratorServer) now routes it to `manager.cancelPrompt`,
        // which broadcasts `turnComplete` to every subscriber.
        try? await session.cancelPrompt(promptID: promptID)
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
}
