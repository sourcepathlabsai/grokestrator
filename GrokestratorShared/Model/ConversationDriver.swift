import Foundation
import GrokestratorCore

/// Single seam between the UI and the actual conversation source — local
/// in-process (`LiveConversationDriver`) or over the wire to a remote GKSS
/// (`RemoteConversationDriver`).
///
/// **Broadcast model (PR B):** the driver no longer hands the caller a per-call
/// stream of updates. Instead, the caller `subscribe()`s once and receives every
/// update for the Connection — including snapshots on join and updates
/// initiated from *other* clients. `send` is fire-and-forget.
public protocol ConversationDriver: Sendable {
    /// Fire a prompt at the underlying source. Updates flow out via `subscribe()`
    /// (which must be running on this driver), not back through this call.
    func send(_ prompt: String) async throws

    /// Open the Connection's broadcast stream. First event is `.snapshot` with
    /// the current transcript; subsequent events are `.update`s indefinitely,
    /// covering updates initiated from any client.
    func subscribe() async -> AsyncStream<ConnectionStreamEvent>

    /// Answer a pending permission request with the chosen ACP `optionId`.
    func respondToPermission(permissionId: String, optionId: String) async

    /// Stops the currently in-flight turn (Stop button). Best-effort: tells
    /// the underlying agent to stop, and locally unwinds the active stream so
    /// `turnComplete` rides through the broadcast and every connected device's
    /// spinner clears.
    func cancel() async

    /// The instance's capabilities (model, MCP servers, slash commands).
    func capabilities() async -> AgentCapabilities?

    /// Token / context usage for the session (inspector).
    func usage() async -> SessionUsage?
}

#if os(macOS)
/// Drives a conversation against the local Mac's own `GrokBuildManager` —
/// the in-process equivalent of `RemoteConversationDriver`. **Mac-only**:
/// iOS is a client-only app and never hosts its own grok processes; it always
/// drives over the wire via `RemoteConversationDriver`.
public struct LiveConversationDriver: ConversationDriver {
    public let manager: GrokBuildManager
    public let instanceID: UUID

    public init(manager: GrokBuildManager, instanceID: UUID) {
        self.manager = manager
        self.instanceID = instanceID
    }

    public func send(_ prompt: String) async throws {
        _ = try await manager.sendPrompt(to: instanceID, prompt: prompt)
    }

    public func subscribe() async -> AsyncStream<ConnectionStreamEvent> {
        // Race-tolerant: when a Connection has just been created, the UI's
        // `.task` may call this before `manager.startInstance` has set up the
        // underlying `GrokBuildConversation`. Wait for the conversation to
        // exist (polling every ~300ms) then forward all events. Cancellation
        // of the outer stream (view goes away) cancels the wait.
        let manager = self.manager
        let instanceID = self.instanceID
        return AsyncStream<ConnectionStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let inner = try? await manager.subscribe(to: instanceID) {
                        for await event in inner {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        break    // inner stream ended cleanly
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)   // retry until the instance is alive
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respondToPermission(permissionId: String, optionId: String) async {
        try? await manager.respondToPermission(for: instanceID, permissionId: permissionId, chosenOption: optionId)
    }

    public func cancel() async {
        await manager.cancelPrompt(for: instanceID)
    }

    public func capabilities() async -> AgentCapabilities? {
        try? await manager.capabilities(for: instanceID)
    }

    public func usage() async -> SessionUsage? {
        await manager.usage(for: instanceID)
    }
}
#endif

// `MockConversationDriver` was removed once persisted Connections + the
// remote-server path covered every demo + dev workflow. If an offline
// scripted driver is ever wanted again, `git log -- GrokestratorShared/Model`
// has the last known-good shape.
